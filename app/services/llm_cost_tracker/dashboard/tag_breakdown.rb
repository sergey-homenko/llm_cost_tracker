# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    class TagBreakdown
      DEFAULT_LIMIT = 100
      SORT_OPTIONS = %w[value calls cost avg_cost].freeze
      DEFAULT_DIRECTIONS = { "value" => "asc", "calls" => "desc", "cost" => "desc", "avg_cost" => "desc" }.freeze
      Row = Data.define(:value, :calls, :total_cost, :average_cost_per_call, :share_percent)

      class << self
        def call(key:, scope: LlmCostTracker::Call.all, limit: DEFAULT_LIMIT, sort: "cost", direction: nil)
          new(scope: scope, key: key, limit: limit, sort: sort, direction: direction)
        end
      end

      attr_reader :limit

      def initialize(scope:, key:, limit:, sort: "cost", direction: nil)
        @scope = scope
        @key = LlmCostTracker::Tags::Key.validate!(key, error_class: LlmCostTracker::InvalidFilterError)
        limit = limit.to_i
        @limit = limit.positive? ? [limit, DEFAULT_LIMIT].min : DEFAULT_LIMIT
        @sort = SORT_OPTIONS.include?(sort.to_s) ? sort.to_s : "cost"
        @direction = Sort::DIRECTIONS.include?(direction.to_s) ? direction.to_s : DEFAULT_DIRECTIONS[@sort]
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

      attr_reader :scope, :key, :sort, :direction

      def summary_counts
        @summary_counts ||= scope.klass.find_by_sql(summary_sql).first
      end

      def rows_sql
        <<~SQL.squish
          SELECT #{tag_value_column} AS value,
                 COUNT(*) AS calls,
                 COALESCE(SUM(sub.total_cost), 0) AS total_cost,
                 COALESCE(SUM(sub.total_cost), 0) / NULLIF(COUNT(*), 0) AS average_cost_per_call
          FROM (#{scope.to_sql}) AS sub
          INNER JOIN #{call_tag_table} t ON t.llm_cost_tracker_call_id = sub.id AND t.#{quote_column('key')} = #{quoted_key}
          WHERE #{tag_present_predicate}
          GROUP BY #{tag_value_column}
          ORDER BY #{order_clause}
          LIMIT #{limit}
        SQL
      end

      def order_clause
        dir = direction.upcase
        case sort
        when "value"    then "#{tag_value_column} #{dir}"
        when "calls"    then "COUNT(*) #{dir}, total_cost DESC"
        when "avg_cost" then "average_cost_per_call #{dir}, total_cost DESC"
        else "total_cost #{dir}, calls DESC, value ASC"
        end
      end

      def summary_sql
        <<~SQL.squish
          SELECT COUNT(*) AS total_calls,
                 COUNT(t.#{quote_column('value')}) AS tagged_calls,
                 COUNT(DISTINCT CASE WHEN #{tag_present_predicate} THEN #{tag_value_column} END) AS distinct_values
          FROM (#{scope.to_sql}) AS sub
          LEFT OUTER JOIN #{call_tag_table} t ON t.llm_cost_tracker_call_id = sub.id AND t.#{quote_column('key')} = #{quoted_key}
        SQL
      end

      def tag_present_predicate
        "#{tag_value_column} IS NOT NULL AND #{tag_value_column} != ''"
      end

      def tag_value_column
        "t.#{quote_column('value')}"
      end

      def call_tag_table
        LlmCostTracker::CallTag.quoted_table_name
      end

      def quote_column(name)
        scope.connection.quote_column_name(name)
      end

      def quoted_key
        scope.connection.quote(key)
      end

      def percentage(numerator, denominator)
        return 0.0 unless denominator.positive?

        (numerator / denominator.to_f) * 100.0
      end
    end
  end
end
