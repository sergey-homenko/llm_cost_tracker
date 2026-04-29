# frozen_string_literal: true

require "llm_cost_tracker/storage/active_record_store"

module LlmCostTracker
  module Dashboard
    OverviewStatsData = Data.define(
      :total_cost,
      :total_calls,
      :average_cost_per_call,
      :average_latency_ms,
      :unknown_pricing_count,
      :previous_total_cost,
      :previous_total_calls,
      :cost_delta_percent,
      :calls_delta_percent,
      :monthly_budget_status
    )

    class OverviewStats
      class << self
        def call(scope: LlmCostTracker::LlmApiCall.all, previous_scope: nil)
          current = aggregate(scope)
          total_calls = current.calls_count.to_i
          total_cost = current.total_cost_sum.to_f

          previous = previous_scope && aggregate(previous_scope)
          prev_cost = previous&.total_cost_sum.to_f
          prev_calls = previous&.calls_count.to_i

          OverviewStatsData.new(
            total_cost: total_cost,
            total_calls: total_calls,
            average_cost_per_call: total_calls.positive? ? total_cost / total_calls : 0.0,
            average_latency_ms: latency_value(current, scope),
            unknown_pricing_count: current.unknown_pricing_count.to_i,
            previous_total_cost: previous ? prev_cost : nil,
            previous_total_calls: previous ? prev_calls : nil,
            cost_delta_percent: previous ? delta_percent(total_cost, prev_cost) : nil,
            calls_delta_percent: previous ? delta_percent(total_calls, prev_calls) : nil,
            monthly_budget_status: budget_status
          )
        end

        private

        def aggregate(scope)
          scope.select(aggregate_selects(scope)).take
        end

        def aggregate_selects(scope)
          selects = [
            "COUNT(*) AS calls_count",
            "COALESCE(SUM(total_cost), 0) AS total_cost_sum",
            "SUM(CASE WHEN total_cost IS NULL THEN 1 ELSE 0 END) AS unknown_pricing_count"
          ]
          selects << "AVG(latency_ms) AS average_latency" if scope.klass.latency_column?
          selects.join(", ")
        end

        def latency_value(row, scope)
          return nil unless scope.klass.latency_column?

          row.average_latency&.to_f
        end

        def delta_percent(current, previous)
          current = current.to_f
          previous = previous.to_f
          return nil if previous.zero?

          ((current - previous) / previous) * 100.0
        end

        def budget_status
          budget = LlmCostTracker.configuration.monthly_budget
          return nil unless budget

          now = Time.now.utc
          month_start = now.beginning_of_month
          month_end = now.end_of_month
          spent = LlmCostTracker::Storage::ActiveRecordStore.monthly_total(time: now)
          elapsed_seconds = now - month_start
          total_seconds = month_end - month_start
          projected_spent = if spent.zero? || !elapsed_seconds.positive?
                              spent
                            else
                              spent * (total_seconds / elapsed_seconds)
                            end

          {
            budget: budget.to_f,
            spent: spent,
            percent_used: budget.to_f.positive? ? (spent / budget.to_f) * 100.0 : 0.0,
            projected_spent: projected_spent,
            projected_percent_used: budget.to_f.positive? ? (projected_spent / budget.to_f) * 100.0 : 0.0,
            projected_delta: projected_spent - budget.to_f,
            projection_end_label: month_end.strftime("%b %-d")
          }
        end
      end
    end
  end
end
