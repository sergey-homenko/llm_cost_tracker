# frozen_string_literal: true

require "llm_cost_tracker/ledger"

module LlmCostTracker
  module Dashboard
    class OverviewStats
      class << self
        def call(scope: LlmCostTracker::Ledger::Call.all, previous_scope: nil)
          return scope.select(aggregate_selects).take unless previous_scope

          scope.klass
               .from("(#{scope.unscope(:select, :order).to_sql}) AS current_calls")
               .joins("CROSS JOIN (#{previous_aggregate_sql(previous_scope)}) AS previous_stats")
               .select(aggregate_selects(table_name: "current_calls", previous: true))
               .take
        end

        def monthly_budget_status
          budget = LlmCostTracker.configuration.monthly_budget
          return nil unless budget

          budget = budget.to_f
          now = Time.now.utc
          month_start = now.beginning_of_month
          month_end = now.end_of_month
          spent = LlmCostTracker::Ledger::Period::Totals.call(%i[monthly], time: now).fetch(:monthly)
          elapsed_seconds = now - month_start
          total_seconds = month_end - month_start
          projected_spent = if spent.zero? || !elapsed_seconds.positive?
                              spent
                            else
                              spent * (total_seconds / elapsed_seconds)
                            end
          percent_used = budget.positive? ? (spent / budget) * 100.0 : 0.0
          projected_percent_used = budget.positive? ? (projected_spent / budget) * 100.0 : 0.0
          projected_delta = projected_spent - budget

          {
            budget: budget,
            spent: spent,
            percent_used: percent_used,
            projected_spent: projected_spent,
            projected_percent_used: projected_percent_used,
            projected_delta: projected_delta,
            projection_end_label: month_end.strftime("%b %-d"),
            fill_modifier: budget_fill_modifier(percent_used),
            progress_percent: clamped_percent(percent_used),
            projected_marker_percent: clamped_percent(projected_percent_used),
            projected_delta_amount: projected_delta.abs,
            projected_delta_direction: projected_delta.positive? ? "over" : "under",
            projected_delta_status_class: projected_delta_status_class(projected_delta)
          }
        end

        private

        def aggregate_selects(table_name: nil, previous: false)
          total_cost = table_name ? "#{table_name}.total_cost" : "total_cost"
          latency_ms = table_name ? "#{table_name}.latency_ms" : "latency_ms"
          average_cost_sql = <<~SQL.squish
            CASE WHEN COUNT(*) > 0
            THEN COALESCE(SUM(#{total_cost}), 0) * 1.0 / COUNT(*)
            ELSE 0 END
          SQL
          selects = [
            "COUNT(*) AS total_calls",
            "COALESCE(SUM(#{total_cost}), 0) AS total_cost",
            "#{average_cost_sql} AS average_cost_per_call",
            "SUM(CASE WHEN #{total_cost} IS NULL THEN 1 ELSE 0 END) AS unknown_pricing_count",
            "AVG(#{latency_ms}) AS average_latency_ms"
          ]
          selects.concat(previous_selects(previous))
          selects.join(", ")
        end

        def previous_selects(previous)
          unless previous
            return [
              "NULL AS previous_total_cost",
              "NULL AS previous_total_calls",
              "NULL AS cost_delta_percent",
              "NULL AS calls_delta_percent"
            ]
          end

          previous_cost_sql = "MAX(previous_stats.total_cost)"
          previous_calls_sql = "MAX(previous_stats.total_calls)"
          cost_delta_sql = <<~SQL.squish
            CASE WHEN (#{previous_cost_sql}) = 0 THEN NULL
            ELSE ((COALESCE(SUM(current_calls.total_cost), 0) - (#{previous_cost_sql})) * 100.0 / (#{previous_cost_sql}))
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

        def previous_aggregate_sql(scope)
          scope
            .unscope(:select, :order)
            .select("COALESCE(SUM(total_cost), 0) AS total_cost", "COUNT(*) AS total_calls")
            .to_sql
        end

        def clamped_percent(value)
          value.clamp(0.0, 100.0)
        end

        def budget_fill_modifier(percent)
          return "lct-budget-fill--over" if percent >= 100.0
          return "lct-budget-fill--warn" if percent >= 80.0

          ""
        end

        def projected_delta_status_class(delta)
          return "lct-budget-projection-status--over" if delta.positive?

          "lct-budget-projection-status--under"
        end
      end
    end
  end
end
