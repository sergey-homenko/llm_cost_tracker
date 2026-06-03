# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    module OverviewStats
      class << self
        def call(scope: LlmCostTracker::Call.all, previous_scope: nil)
          return scope.select(aggregate_selects).take unless previous_scope

          scope.klass
               .from("(#{scope.unscope(:select, :order).to_sql}) AS current_calls")
               .joins("CROSS JOIN (#{previous_aggregate_sql(previous_scope)}) AS previous_stats")
               .select(aggregate_selects(table_name: "current_calls", previous: true))
               .take
        end

        private

        def aggregate_selects(table_name: nil, previous: false)
          total_cost = table_name ? "#{table_name}.total_cost" : "total_cost"
          latency_ms = table_name ? "#{table_name}.latency_ms" : "latency_ms"
          cost_status = table_name ? "#{table_name}.cost_status" : "cost_status"
          average_cost_sql = <<~SQL.squish
            CASE WHEN COUNT(*) > 0
            THEN COALESCE(SUM(#{total_cost}), 0) * 1.0 / COUNT(*)
            ELSE 0 END
          SQL
          predicate = LlmCostTracker::Charges::CostStatus.unknown_pricing_sql(
            total_cost: total_cost, cost_status: cost_status
          )
          unknown_pricing_sql = "SUM(CASE WHEN #{predicate} THEN 1 ELSE 0 END)"
          selects = [
            "COUNT(*) AS total_calls",
            "COALESCE(SUM(#{total_cost}), 0) AS total_cost",
            "#{average_cost_sql} AS average_cost_per_call",
            "#{unknown_pricing_sql} AS unknown_pricing_count",
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
      end
    end
  end
end
