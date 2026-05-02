# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    class TagBreakdown
      DEFAULT_LIMIT = 100
      Row = Data.define(:value, :calls, :total_cost, :average_cost_per_call, :share_percent)

      class << self
        def call(key:, scope: LlmCostTracker::Ledger::Call.all, limit: DEFAULT_LIMIT)
          new(scope: scope, key: key, limit: limit)
        end
      end

      attr_reader :limit

      def initialize(scope:, key:, limit:)
        @scope = scope
        @key = LlmCostTracker::Tags::Key.validate!(key, error_class: LlmCostTracker::InvalidFilterError)
        limit = limit.to_i
        @limit = limit.positive? ? [limit, DEFAULT_LIMIT].min : DEFAULT_LIMIT
      end

      def rows
        @rows ||= begin
          total = tagged_calls
          scope.klass.find_by_sql(rows_sql).map do |row|
            calls = row.calls.to_i
            Row.new(
              value: row.value,
              calls: calls,
              total_cost: row.total_cost,
              average_cost_per_call: row.average_cost_per_call,
              share_percent: percentage(calls, total)
            )
          end
        end
      end

      def total_calls
        summary_counts.total_calls.to_i
      end

      def tagged_calls
        summary_counts.tagged_calls.to_i
      end

      def distinct_values
        summary_counts.distinct_values.to_i
      end

      private

      attr_reader :scope, :key

      def summary_counts
        @summary_counts ||= scope.klass.find_by_sql(summary_sql).first
      end

      def rows_sql
        <<~SQL.squish
          SELECT #{tag_expression} AS value,
                 COUNT(*) AS calls,
                 COALESCE(SUM(sub.total_cost), 0) AS total_cost,
                 COALESCE(SUM(sub.total_cost), 0) / NULLIF(COUNT(*), 0) AS average_cost_per_call
          FROM (#{scope.to_sql}) AS sub
          WHERE #{tag_present_predicate}
          GROUP BY #{tag_expression}
          ORDER BY total_cost DESC, calls DESC, value ASC
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
        @tag_expression ||= LlmCostTracker::Ledger::Tags::Sql.value_expression(key, table_name: "sub")
      end

      def percentage(numerator, denominator)
        return 0.0 unless denominator.positive?

        (numerator / denominator.to_f) * 100.0
      end
    end
  end
end
