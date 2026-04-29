# frozen_string_literal: true

require_relative "inbox"
require_relative "periods"
require_relative "rollups"

module LlmCostTracker
  class PeriodTotals
    def self.call(periods, time:)
      new(periods, time: time).totals
    end

    def initialize(periods, time:)
      @periods = Periods.valid_keys(periods)
      @time = time
    end

    def totals
      return {} if periods.empty?
      return Rollups.period_totals(periods, time: time) unless Inbox.enabled?

      snapshot_totals
    end

    private

    attr_reader :periods, :time

    def snapshot_totals
      values = periods.to_h { |period| [period, 0.0] }
      connection.select_all(periods.map { |period| snapshot_select(period) }.join(" UNION ALL ")).each do |row|
        values[row.fetch("period_key").to_sym] = row.fetch("total_cost").to_f
      end
      values
    end

    def snapshot_select(period)
      start = Periods.range_start(period, time)
      "SELECT #{connection.quote(period.to_s)} AS period_key, " \
        "(#{stored_total_sql(period, start)}) + (#{pending_total_sql(start)}) AS total_cost"
    end

    def stored_total_sql(period, start)
      if connection.data_source_exists?("llm_cost_tracker_period_totals")
        rollup_total_sql(period)
      else
        ledger_total_sql(start)
      end
    end

    def rollup_total_sql(period)
      table = connection.quote_table_name("llm_cost_tracker_period_totals")
      "COALESCE((SELECT total_cost FROM #{table} " \
        "WHERE period = #{connection.quote(Periods::PERIODS.fetch(period))} " \
        "AND period_start = #{connection.quote(Periods.bucket(period, time))} LIMIT 1), 0)"
    end

    def ledger_total_sql(start)
      table = LlmCostTracker::LlmApiCall.quoted_table_name
      total_cost = connection.quote_column_name("total_cost")
      tracked_at = connection.quote_column_name("tracked_at")
      "COALESCE((SELECT SUM(#{total_cost}) FROM #{table} " \
        "WHERE #{tracked_at} BETWEEN #{connection.quote(start)} AND #{connection.quote(time)}), 0)"
    end

    def pending_total_sql(start)
      table = connection.quote_table_name(Inbox::TABLE_NAME)
      total_cost = connection.quote_column_name("total_cost")
      tracked_at = connection.quote_column_name("tracked_at")
      attempts = connection.quote_column_name("attempts")
      "COALESCE((SELECT SUM(#{total_cost}) FROM #{table} " \
        "WHERE #{attempts} < #{Inbox::MAX_ATTEMPTS} " \
        "AND #{tracked_at} BETWEEN #{connection.quote(start)} AND #{connection.quote(time)}), 0)"
    end

    def connection
      LlmCostTracker::LlmApiCall.connection
    end
  end
end
