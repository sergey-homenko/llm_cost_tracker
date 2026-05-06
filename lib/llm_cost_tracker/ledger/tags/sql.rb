# frozen_string_literal: true

require_relative "../../tags/key"

module LlmCostTracker
  module Ledger
    module Tags
      module Sql
        UNTAGGED_LABEL = "(untagged)"

        class << self
          def join_relation(scope, key)
            validated_key = LlmCostTracker::Tags::Key.validate!(key)
            connection = scope.connection
            join = "LEFT OUTER JOIN #{call_tag_table} ON " \
                   "#{call_tag_table}.llm_cost_tracker_call_id = #{scope.quoted_table_name}.id AND " \
                   "#{call_tag_table}.#{connection.quote_column_name('key')} = #{connection.quote(validated_key)}"
            scope.joins(join)
          end

          def value_arel
            Arel.sql("#{call_tag_table}.#{quote_column('value')}")
          end

          def label_sql(connection)
            value_column = "#{call_tag_table}.#{connection.quote_column_name('value')}"
            "COALESCE(NULLIF(#{value_column}, ''), #{connection.quote(UNTAGGED_LABEL)})"
          end

          private

          def call_tag_table
            LlmCostTracker::CallTag.quoted_table_name
          end

          def quote_column(name)
            LlmCostTracker::CallTag.connection.quote_column_name(name)
          end
        end
      end
    end
  end
end
