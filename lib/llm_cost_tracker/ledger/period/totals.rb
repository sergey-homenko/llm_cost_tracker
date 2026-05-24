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
          components << pending_total_sql(start) if Ingestion.async?
          "SELECT #{connection.quote(period.name)} AS period_key, " \
            "(#{components.join(') + (')}) AS total_cost"
        end

        def period_total_sql(period, start)
          if LlmCostTracker.configuration.cache_rollups
            "GREATEST(COALESCE(#{rollup_sum_sql(period)}, 0), COALESCE(#{calls_sum_sql(start)}, 0))"
          else
            "COALESCE(#{calls_sum_sql(start)}, 0)"
          end
        end

        def rollup_sum_sql(period)
          table = connection.quote_table_name("llm_cost_tracker_call_rollups")
          "(SELECT SUM(total_cost) FROM #{table} " \
            "WHERE period = #{connection.quote(period.to_s)} " \
            "AND period_start = #{connection.quote(Period.bucket(period, time))})"
        end

        def calls_sum_sql(start)
          table = connection.quote_table_name("llm_cost_tracker_calls")
          tracked_at = connection.quote_column_name("tracked_at")
          "(SELECT SUM(total_cost) FROM #{table} " \
            "WHERE #{tracked_at} BETWEEN #{connection.quote(start)} AND #{connection.quote(time)})"
        end

        def pending_total_sql(start)
          table = connection.quote_table_name(Ingestion::InboxEntry.table_name)
          total_cost = connection.quote_column_name("total_cost")
          tracked_at = connection.quote_column_name("tracked_at")
          attempts = connection.quote_column_name("attempts")
          "COALESCE((SELECT SUM(#{total_cost}) FROM #{table} " \
            "WHERE #{attempts} < #{Ingestion::InboxEntry::MAX_ATTEMPTS_BEFORE_QUARANTINE} " \
            "AND #{tracked_at} BETWEEN #{connection.quote(start)} AND #{connection.quote(time)}), 0)"
        end

        def connection
          LlmCostTracker::Call.connection
        end
      end
    end
  end
end
