# frozen_string_literal: true

require "bigdecimal/util"

require_relative "../isolation"
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
          Isolation.guard { LlmCostTracker::Call.find_by_sql(union_sql) }.each do |row|
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
          components = ["(#{recorded_sql(start)})"]
          components << "(#{pending_sql(start)})" if Ingestion.async?
          "SELECT #{quote(period.to_s)} AS period_key, #{components.join(' + ')} AS total_cost"
        end

        def recorded_sql(start)
          today = Period.range_start(:day, time)
          return calls_sql(start) unless Rollups.cache_active? && start < today

          "#{completed_days_sql(start, today)} + #{calls_sql(today)}"
        end

        def calls_sql(start)
          "COALESCE(#{sum_sql(LlmCostTracker::Call.between(start, time))}, 0)"
        end

        def completed_days_sql(start, today)
          days = LlmCostTracker::CallRollup.where(period: "day", period_start: start.to_date...today.to_date)
          "COALESCE(#{sum_sql(days)}, 0)"
        end

        def pending_sql(start)
          "COALESCE(#{sum_sql(Ingestion::InboxEntry.pending.where(tracked_at: start..time))}, 0)"
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
