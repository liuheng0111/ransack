require 'ransack/context'
require 'ransack/adapters/active_record/compat'
require 'polyamorous'

module Ransack
  module Adapters
    module ActiveRecord
      class Context < ::Ransack::Context

        # Because the AR::Associations namespace is insane
        if defined? ::ActiveRecord::Associations::JoinDependency
          JoinDependency = ::ActiveRecord::Associations::JoinDependency
        end

        def initialize(object, options = {})
          super
          if ::ActiveRecord::VERSION::STRING < Constants::RAILS_5_2
            @arel_visitor = @engine.connection.visitor
          end
        end

        def relation_for(object)
          object.all
        end

        def type_for(attr)
          return nil unless attr && attr.valid?
          name         = attr.arel_attribute.name.to_s
          table        = attr.arel_attribute.relation.table_name
          schema_cache = self.klass.connection.schema_cache
          unless schema_cache.send(:data_source_exists?, table)
            raise "No table named #{table} exists."
          end
          attr.klass.columns.find { |column| column.name == name }.type
        end

        def evaluate(search, opts = {})
          viz = Visitor.new
          relation = @object.where(viz.accept(search.base))
          if search.sorts.any?
            relation = relation.except(:order).reorder(viz.accept(search.sorts))
          end
          opts[:distinct] ? relation.distinct : relation
        end

        def attribute_method?(str, klass = @klass)
          exists = false
          if ransackable_attribute?(str, klass)
            exists = true
          elsif (segments = str.split(Constants::UNDERSCORE)).size > 1
            remainder = []
            found_assoc = nil
            while !found_assoc && remainder.unshift(segments.pop) &&
            segments.size > 0 do
              assoc, poly_class = unpolymorphize_association(
                segments.join(Constants::UNDERSCORE)
                )
              if found_assoc = get_association(assoc, klass)
                exists = attribute_method?(
                  remainder.join(Constants::UNDERSCORE),
                  poly_class || found_assoc.klass
                  )
              end
            end
          end
          exists
        end

        def table_for(parent)
          parent.table
        end

        def klassify(obj)
          if Class === obj && ::ActiveRecord::Base > obj
            obj
          elsif obj.respond_to? :klass
            obj.klass
          elsif obj.respond_to? :base_klass
            obj.base_klass
          else
            raise ArgumentError, "Don't know how to klassify #{obj}"
          end
        end

        # All dependent Arel::Join nodes used in the search query.
        #
        # This could otherwise be done as `@object.arel.join_sources`, except
        # that ActiveRecord's build_joins sets up its own JoinDependency.
        # This extracts what we need to access the joins using our existing
        # JoinDependency to track table aliases.
        #
        def join_sources
          base, joins = [
            Arel::SelectManager.new(@object.table),
            @join_dependency.join_constraints(@object.joins_values, @join_type)
          ]
          joins = joins.collect(&:joins).flatten if ::ActiveRecord::VERSION::STRING < Constants::RAILS_5_2
          joins.each do |aliased_join|
            base.from(aliased_join)
          end
          base.join_sources
        end

        def alias_tracker
          @join_dependency.send(:alias_tracker)
        end

        def lock_association(association)
          @lock_associations << association
        end

        def remove_association(association)
          return if @lock_associations.include?(association)
          @join_dependency.instance_variable_get(:@join_root).children.delete_if { |stashed|
            stashed.eql?(association)
          }
          @object.joins_values.delete_if { |jd|
            jd.instance_variable_get(:@join_root).children.map(&:object_id) == [association.object_id]
          }
        end

        # Build an Arel subquery that selects keys for the top query,
        # drawn from the first join association's foreign_key.
        #
        # Example: for an Article that has_and_belongs_to_many Tags
        #
        #   context = Article.search.context
        #   attribute = Attribute.new(context, "tags_name").tap do |a|
        #     context.bind(a, a.name)
        #   end
        #   context.build_correlated_subquery(attribute.parent).to_sql
        #
        #   # SELECT "articles_tags"."article_id" FROM "articles_tags"
        #   # INNER JOIN "tags" ON "tags"."id" = "articles_tags"."tag_id"
        #   # WHERE "articles_tags"."article_id" = "articles"."id"
        #
        # The WHERE condition on this query makes it invalid by itself,
        # because it is correlated to the primary key on the outer query.
        #
        def build_correlated_subquery(association)
          join_constraints = extract_joins(association)
          join_root = join_constraints.shift
          correlated_key = join_root.right.expr.left
          subquery = Arel::SelectManager.new(association.base_klass)
          subquery.from(join_root.left)
          subquery.project(correlated_key)
          join_constraints.each do |j|
            subquery.join_sources << Arel::Nodes::InnerJoin.new(j.left, j.right)
          end
          subquery.where(correlated_key.eq(primary_key))
        end

        def primary_key
          @object.table[@object.primary_key]
        end

        private

        def get_parent_and_attribute_name(str, parent = @base)
          attr_name = nil

          if ransackable_attribute?(str, klassify(parent))
            attr_name = str
          elsif (segments = str.split(Constants::UNDERSCORE)).size > 1
            remainder = []
            found_assoc = nil
            while remainder.unshift(segments.pop) && segments.size > 0 &&
            !found_assoc do
              assoc, klass = unpolymorphize_association(
                segments.join(Constants::UNDERSCORE)
                )
              if found_assoc = get_association(assoc, parent)
                join = build_or_find_association(
                  found_assoc.name, parent, klass
                  )
                parent, attr_name = get_parent_and_attribute_name(
                  remainder.join(Constants::UNDERSCORE), join
                  )
              end
            end
          end

          [parent, attr_name]
        end

        def get_association(str, parent = @base)
          klass = klassify parent
          ransackable_association?(str, klass) &&
          klass.reflect_on_all_associations.detect { |a| a.name.to_s == str }
        end

        def join_dependency(relation)
          if relation.respond_to?(:join_dependency) # Polyamorous enables this
            relation.join_dependency
          else
            build_joins(relation)
          end
        end

        # Checkout active_record/relation/query_methods.rb +build_joins+ for
        # reference. Lots of duplicated code maybe we can avoid it
        def build_joins(relation)
          buckets = relation.joins_values + relation.left_outer_joins_values

          buckets = buckets.group_by do |join|
            case join
            when String
              :string_join
            when Hash, Symbol, Array
              :association_join
            when Polyamorous::JoinDependency, Polyamorous::JoinAssociation
              :stashed_join
            when Arel::Nodes::Join
              :join_node
            else
              raise 'unknown class: %s' % join.class.name
            end
          end
          buckets.default = []
          association_joins         = buckets[:association_join]
          stashed_association_joins = buckets[:stashed_join]
          join_nodes                = buckets[:join_node].uniq
          string_joins              = buckets[:string_join].map(&:strip)
          string_joins.uniq!

          join_list = join_nodes + convert_join_strings_to_ast(relation.table, string_joins)

          if ::ActiveRecord::VERSION::STRING < Constants::RAILS_5_2
            join_dependency = JoinDependency.new(relation.klass, association_joins, join_list)
            join_nodes.each do |join|
              join_dependency.send(:alias_tracker).aliases[join.left.name.downcase] = 1
            end
          else
            alias_tracker = ::ActiveRecord::Associations::AliasTracker.create(self.klass.connection, relation.table.name, join_list)
            join_dependency = JoinDependency.new(relation.klass, relation.table, association_joins, alias_tracker)
            join_nodes.each do |join|
              join_dependency.send(:alias_tracker).aliases[join.left.name.downcase] = 1
            end
          end
          join_dependency
        end

        def convert_join_strings_to_ast(table, joins)
          joins.map! { |join| table.create_string_join(Arel.sql(join)) unless join.blank? }
          joins.compact!
          joins
        end

        def build_or_find_association(name, parent = @base, klass = nil)
          find_association(name, parent, klass) or build_association(name, parent, klass)
        end

        def find_association(name, parent = @base, klass = nil)
          @join_dependency.instance_variable_get(:@join_root).children.detect do |assoc|
            assoc.reflection.name == name &&
            (@associations_pot.empty? || @associations_pot[assoc] == parent || !@associations_pot.key?(assoc)) &&
            (!klass || assoc.reflection.klass == klass)
          end
        end

        def build_association(name, parent = @base, klass = nil)
          if ::ActiveRecord::VERSION::STRING < Constants::RAILS_5_2
            jd = JoinDependency.new(
              parent.base_klass,
              Polyamorous::Join.new(name, @join_type, klass),
              []
            )
            found_association = jd.join_root.children.last
          else
            alias_tracker = ::ActiveRecord::Associations::AliasTracker.create(self.klass.connection, parent.table.name, [])
            jd = JoinDependency.new(
              parent.base_klass,
              parent.base_klass.arel_table,
              Polyamorous::Join.new(name, @join_type, klass),
              alias_tracker
            )
            found_association = jd.instance_variable_get(:@join_root).children.last
          end


          @associations_pot[found_association] = parent

          # TODO maybe we dont need to push associations here, we could loop
          # through the @associations_pot instead
          @join_dependency.instance_variable_get(:@join_root).children.push found_association

          # Builds the arel nodes properly for this association
          @join_dependency.send(
            :construct_tables!, jd.instance_variable_get(:@join_root), found_association
            )

          # Leverage the stashed association functionality in AR
          @object = @object.joins(jd)

          found_association
        end

        def extract_joins(association)
          parent = @join_dependency.instance_variable_get(:@join_root)
          reflection = association.reflection
          join_constraints = if ::ActiveRecord::VERSION::STRING < Constants::RAILS_5_1
                               association.join_constraints(
                                 parent.table,
                                 parent.base_klass,
                                 association,
                                 Arel::Nodes::OuterJoin,
                                 association.tables,
                                 reflection.scope_chain,
                                 reflection.chain
                               )
                             else
                               association.join_constraints(
                                 parent.table,
                                 parent.base_klass,
                                 Arel::Nodes::OuterJoin,
                                 association.tables,
                                 reflection.chain
                               )
                             end
          join_constraints.to_a.flatten
        end
      end
    end
  end
end
