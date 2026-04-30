# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    class TopModels
      DEFAULT_LIMIT = 5
      SORT_OPTIONS = %w[cost calls avg_cost latency].freeze
      DEFAULT_SORT = "cost"

      class << self
        def call(scope: LlmCostTracker::Ledger::Call.all, limit: DEFAULT_LIMIT, sort: DEFAULT_SORT)
          new(scope: scope, limit: limit, sort: sort).rows
        end
      end

      def initialize(scope:, limit:, sort: DEFAULT_SORT)
        @scope = scope
        @limit = limit
        @sort = SORT_OPTIONS.include?(sort.to_s) ? sort.to_s : DEFAULT_SORT
      end

      def rows
        grouped_rows
      end

      private

      attr_reader :scope, :limit, :sort

      def grouped_rows
        scope
          .group(:provider, :model)
          .select(selects)
          .order(Arel.sql(order_sql))
          .then { |r| limit ? r.limit(limit) : r }
      end

      def order_sql
        case sort
        when "calls"
          "COUNT(*) DESC"
        when "avg_cost"
          "COALESCE(SUM(total_cost), 0) / NULLIF(COUNT(*), 0) DESC"
        when "latency"
          return "COALESCE(SUM(total_cost), 0) DESC" unless scope.klass.latency_column?

          "CASE WHEN AVG(latency_ms) IS NULL THEN 1 ELSE 0 END ASC, AVG(latency_ms) DESC"
        else
          "COALESCE(SUM(total_cost), 0) DESC"
        end
      end

      def selects
        columns = [
          "provider",
          "model",
          "COUNT(*) AS calls",
          "COALESCE(SUM(total_cost), 0) AS total_cost",
          "COALESCE(SUM(total_cost), 0) / NULLIF(COUNT(*), 0) AS average_cost_per_call",
          "COALESCE(SUM(input_tokens), 0) AS input_tokens",
          "COALESCE(SUM(output_tokens), 0) AS output_tokens"
        ]
        columns << "AVG(latency_ms) AS average_latency_ms" if scope.klass.latency_column?
        columns.join(", ")
      end
    end
  end
end
