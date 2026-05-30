# frozen_string_literal: true

require "bigdecimal"

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

          snapshot_totals
        end

        private

        attr_reader :periods, :time

        def snapshot_totals
          values = periods.to_h { |period| [period, BigDecimal("0")] }
          period_by_name = periods.to_h { |period| [period.name, period] }
          sql = periods.map { |period| snapshot_select(period) }.join(" UNION ALL ")
          LlmCostTracker::Call.find_by_sql(sql).each do |row|
            period = period_by_name.fetch(row.period_key)
            values[period] = BigDecimal(row.total_cost.to_s)
          end
          values
        end

        def snapshot_select(period)
          start = Period.range_start(period, time)
          components = [period_total_sql(period, start)]
          components << Ingestion::InboxEntry.pending_total_sql(start: start, finish: time) if Ingestion.async?
          "SELECT #{connection.quote(period.name)} AS period_key, " \
            "(#{components.join(') + (')}) AS total_cost"
        end

        def period_total_sql(period, start)
          calls = "COALESCE(#{calls_sum_sql(start)}, 0)"
          return calls unless LlmCostTracker.configuration.cache_rollups

          rollup = LlmCostTracker::CallRollup.total_sql(period: period, period_start: Period.bucket(period, time))
          "GREATEST(COALESCE(#{rollup}, 0), #{calls})"
        end

        def calls_sum_sql(start)
          calls = LlmCostTracker::Call.where(tracked_at: start..time)
          "(#{calls.select('SUM(total_cost)').to_sql})"
        end

        def connection
          LlmCostTracker::Call.connection
        end
      end
    end
  end
end
