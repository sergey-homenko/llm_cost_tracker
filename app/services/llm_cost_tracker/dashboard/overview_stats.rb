# frozen_string_literal: true

require "llm_cost_tracker/ledger"

module LlmCostTracker
  module Dashboard
    class OverviewStats
      class << self
        def call(scope: LlmCostTracker::Ledger::Call.all, previous_scope: nil)
          scope.select(aggregate_selects(scope, previous_scope: previous_scope)).take
        end

        def monthly_budget_status
          budget = LlmCostTracker.configuration.monthly_budget
          return nil unless budget

          now = Time.now.utc
          month_start = now.beginning_of_month
          month_end = now.end_of_month
          spent = LlmCostTracker::Ledger::Store.monthly_total(time: now)
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

        private

        def aggregate_selects(scope, previous_scope:)
          average_cost_sql = <<~SQL.squish
            CASE WHEN COUNT(*) > 0
            THEN COALESCE(SUM(total_cost), 0) * 1.0 / COUNT(*)
            ELSE 0 END
          SQL
          selects = [
            "COUNT(*) AS total_calls",
            "COALESCE(SUM(total_cost), 0) AS total_cost",
            "#{average_cost_sql} AS average_cost_per_call",
            "SUM(CASE WHEN total_cost IS NULL THEN 1 ELSE 0 END) AS unknown_pricing_count"
          ]
          selects << if scope.klass.latency_column?
                       "AVG(latency_ms) AS average_latency_ms"
                     else
                       "NULL AS average_latency_ms"
                     end
          selects.concat(previous_selects(previous_scope))
          selects.join(", ")
        end

        def previous_selects(previous_scope)
          unless previous_scope
            return [
              "NULL AS previous_total_cost",
              "NULL AS previous_total_calls",
              "NULL AS cost_delta_percent",
              "NULL AS calls_delta_percent"
            ]
          end

          previous_cost_sql = aggregate_subquery(previous_scope, "COALESCE(SUM(total_cost), 0)")
          previous_calls_sql = aggregate_subquery(previous_scope, "COUNT(*)")
          cost_delta_sql = <<~SQL.squish
            CASE WHEN (#{previous_cost_sql}) = 0 THEN NULL
            ELSE ((COALESCE(SUM(total_cost), 0) - (#{previous_cost_sql})) * 100.0 / (#{previous_cost_sql}))
            END
          SQL
          calls_delta_sql = <<~SQL.squish
            CASE WHEN (#{previous_calls_sql}) = 0 THEN NULL
            ELSE ((COUNT(*) - (#{previous_calls_sql})) * 100.0 / (#{previous_calls_sql}))
            END
          SQL
          [
            "(#{previous_cost_sql}) AS previous_total_cost",
            "(#{previous_calls_sql}) AS previous_total_calls",
            "#{cost_delta_sql} AS cost_delta_percent",
            "#{calls_delta_sql} AS calls_delta_percent"
          ]
        end

        def aggregate_subquery(scope, expression)
          scope.unscope(:select, :order).select(expression).to_sql
        end
      end
    end
  end
end
