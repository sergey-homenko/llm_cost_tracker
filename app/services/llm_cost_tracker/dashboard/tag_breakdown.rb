# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    TagBreakdownRow = Data.define(
      :value,
      :calls,
      :total_cost,
      :average_cost_per_call
    )

    TagBreakdownResult = Data.define(
      :rows,
      :total_calls,
      :tagged_calls,
      :distinct_values,
      :limit
    ) do
      def limited? = distinct_values > rows.size
    end

    class TagBreakdown
      DEFAULT_LIMIT = 100

      class << self
        def call(key:, scope: LlmCostTracker::LlmApiCall.all, limit: DEFAULT_LIMIT)
          new(scope: scope, key: key, limit: limit).result
        end
      end

      def initialize(scope:, key:, limit:)
        @scope = scope
        @key = LlmCostTracker::TagKey.validate!(key, error_class: LlmCostTracker::InvalidFilterError)
        @limit = normalized_limit(limit)
        @connection = LlmCostTracker::LlmApiCall.connection
      end

      def result
        counts = summary_counts

        TagBreakdownResult.new(
          rows: rows,
          total_calls: counts.fetch(:total_calls),
          tagged_calls: counts.fetch(:tagged_calls),
          distinct_values: counts.fetch(:distinct_values),
          limit: limit
        )
      end

      private

      attr_reader :scope, :key, :limit, :connection

      def rows
        connection.select_all(rows_sql).map do |row|
          calls = row["calls_count"].to_i
          total_cost = row["total_cost_sum"].to_f
          TagBreakdownRow.new(
            value: LlmCostTracker::LlmApiCall.tag_value_label(row["tag_value"]),
            calls: calls,
            total_cost: total_cost,
            average_cost_per_call: calls.positive? ? total_cost / calls : 0.0
          )
        end
      end

      def summary_counts
        row = connection.select_one(summary_sql) || {}
        {
          total_calls: row["total_calls"].to_i,
          tagged_calls: row["tagged_calls"].to_i,
          distinct_values: row["distinct_values"].to_i
        }
      end

      def rows_sql
        <<~SQL.squish
          SELECT #{tag_expression} AS tag_value,
                 COUNT(*) AS calls_count,
                 COALESCE(SUM(sub.total_cost), 0) AS total_cost_sum
          FROM (#{scope.to_sql}) AS sub
          WHERE #{tag_present_predicate}
          GROUP BY #{tag_expression}
          ORDER BY total_cost_sum DESC, calls_count DESC, tag_value ASC
          LIMIT #{limit}
        SQL
      end

      def summary_sql
        <<~SQL.squish
          SELECT COUNT(*) AS total_calls,
                 COALESCE(SUM(CASE WHEN #{tag_present_predicate} THEN 1 ELSE 0 END), 0) AS tagged_calls,
                 COUNT(DISTINCT CASE WHEN #{tag_present_predicate} THEN #{tag_expression} END) AS distinct_values
          FROM (#{scope.to_sql}) AS sub
        SQL
      end

      def tag_present_predicate
        "#{tag_expression} IS NOT NULL AND #{tag_expression} != ''"
      end

      def tag_expression
        @tag_expression ||= LlmCostTracker::LlmApiCall.tag_value_expression(key, table_name: "sub")
      end

      def normalized_limit(value)
        value = value.to_i
        value.positive? ? [value, DEFAULT_LIMIT].min : DEFAULT_LIMIT
      end
    end
  end
end
