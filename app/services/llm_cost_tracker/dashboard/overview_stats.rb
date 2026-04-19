# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    class OverviewStats
      attr_reader :total_cost,
                  :total_calls,
                  :average_cost_per_call,
                  :average_latency_ms,
                  :monthly_budget_status

      def self.call(scope: LlmCostTracker::LlmApiCall.all)
        row = aggregate(scope)
        total_calls = row.calls_count.to_i
        total_cost = row.total_cost_sum.to_f

        new(
          total_cost: total_cost,
          total_calls: total_calls,
          average_cost_per_call: total_calls.positive? ? total_cost / total_calls : 0.0,
          average_latency_ms: latency_value(row, scope),
          monthly_budget_status: budget_status
        )
      end

      def self.aggregate(scope)
        scope.select(aggregate_selects(scope)).take
      end
      private_class_method :aggregate

      def self.aggregate_selects(scope)
        selects = [
          "COUNT(*) AS calls_count",
          "COALESCE(SUM(total_cost), 0) AS total_cost_sum"
        ]
        selects << "AVG(latency_ms) AS average_latency" if scope.klass.latency_column?
        selects.join(", ")
      end
      private_class_method :aggregate_selects

      def self.latency_value(row, scope)
        return nil unless scope.klass.latency_column?

        row.average_latency&.to_f
      end
      private_class_method :latency_value

      def self.budget_status
        budget = LlmCostTracker.configuration.monthly_budget
        return nil unless budget

        spent = LlmCostTracker::LlmApiCall.this_month.total_cost
        {
          budget: budget.to_f,
          spent: spent,
          percent_used: budget.to_f.positive? ? (spent / budget.to_f) * 100.0 : 0.0
        }
      end
      private_class_method :budget_status

      def initialize(total_cost:, total_calls:, average_cost_per_call:, average_latency_ms:, monthly_budget_status:)
        @total_cost = total_cost
        @total_calls = total_calls
        @average_cost_per_call = average_cost_per_call
        @average_latency_ms = average_latency_ms
        @monthly_budget_status = monthly_budget_status
        freeze
      end
    end
  end
end
