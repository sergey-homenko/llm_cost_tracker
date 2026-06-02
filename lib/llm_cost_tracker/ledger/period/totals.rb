# frozen_string_literal: true

require "bigdecimal/util"

require_relative "../period"

module LlmCostTracker
  module Ledger
    module Period
      class Totals
        def self.call(periods, time:)
          new(periods, time: time).totals
        end

        def initialize(periods, time:)
          @periods = Period.valid_keys(periods)
          @time = time
        end

        def totals
          return {} if periods.empty?

          values = periods.to_h { |period| [period, BigDecimal("0")] }
          period_by_name = periods.to_h { |period| [period.to_s, period] }
          LlmCostTracker::Call.find_by_sql(union_sql).each do |row|
            values[period_by_name.fetch(row.period_key)] = row.total_cost.to_d
          end
          values
        end

        private

        attr_reader :periods, :time

        def union_sql
          periods.map { |period| period_select(period) }.join(" UNION ALL ")
        end

        def period_select(period)
          start = Period.range_start(period, time)
          components = ["(#{recorded_sql(period, start)})"]
          components << "(#{pending_sql(start)})" if Ingestion.async?
          "SELECT #{quote(period.to_s)} AS period_key, #{components.join(' + ')} AS total_cost"
        end

        def recorded_sql(period, start)
          calls = "COALESCE(#{sum_sql(LlmCostTracker::Call.between(start, time))}, 0)"
          return calls unless LlmCostTracker.configuration.cache_rollups

          rollup = "COALESCE(#{sum_sql(rollup_scope(period))}, 0)"
          "GREATEST(#{rollup}, #{calls})"
        end

        def pending_sql(start)
          "COALESCE(#{sum_sql(Ingestion::InboxEntry.pending.where(tracked_at: start..time))}, 0)"
        end

        def rollup_scope(period)
          LlmCostTracker::CallRollup.where(period: period.to_s, period_start: Period.bucket(period, time))
        end

        def sum_sql(scope)
          "(#{scope.select('SUM(total_cost)').to_sql})"
        end

        def quote(value)
          LlmCostTracker::Call.connection.quote(value)
        end
      end
    end
  end
end
