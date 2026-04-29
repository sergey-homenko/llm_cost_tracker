# frozen_string_literal: true

require_relative "active_record_inbox"
require_relative "active_record_rollups"

module LlmCostTracker
  module Storage
    class ActiveRecordPeriodTotals
      def self.call(periods, time:)
        new(periods, time: time).totals
      end

      def initialize(periods, time:)
        @periods = periods.map(&:to_sym).select { |period| ActiveRecordRollups::PERIODS.key?(period) }
        @time = time
      end

      def totals
        return {} if periods.empty?
        return ActiveRecordRollups.period_totals(periods, time: time) unless ActiveRecordInbox.enabled?

        snapshot_totals
      end

      private

      attr_reader :periods, :time

      def snapshot_totals
        values = periods.to_h { |period| [period, 0.0] }
        connection.select_all(snapshot_sql).each do |row|
          values[row.fetch("period_key").to_sym] = row.fetch("total_cost").to_f
        end
        values
      end

      def snapshot_sql
        periods.map { |period| snapshot_select(period) }.join(" UNION ALL ")
      end

      def snapshot_select(period)
        start = range_start_for(period)
        "SELECT #{connection.quote(period.to_s)} AS period_key, " \
          "(#{stored_total_sql(period, start)}) + (#{pending_total_sql(start)}) AS total_cost"
      end

      def stored_total_sql(period, start)
        period_totals_table? ? rollup_total_sql(period) : ledger_total_sql(start)
      end

      def rollup_total_sql(period)
        table = connection.quote_table_name("llm_cost_tracker_period_totals")
        "COALESCE((SELECT total_cost FROM #{table} " \
          "WHERE period = #{connection.quote(ActiveRecordRollups::PERIODS.fetch(period))} " \
          "AND period_start = #{connection.quote(bucket_for(period))} LIMIT 1), 0)"
      end

      def ledger_total_sql(start)
        table = LlmCostTracker::LlmApiCall.quoted_table_name
        total_cost = connection.quote_column_name("total_cost")
        tracked_at = connection.quote_column_name("tracked_at")
        "COALESCE((SELECT SUM(#{total_cost}) FROM #{table} " \
          "WHERE #{tracked_at} BETWEEN #{connection.quote(start)} AND #{connection.quote(time)}), 0)"
      end

      def pending_total_sql(start)
        table = connection.quote_table_name(ActiveRecordInbox::TABLE_NAME)
        total_cost = connection.quote_column_name("total_cost")
        tracked_at = connection.quote_column_name("tracked_at")
        attempts = connection.quote_column_name("attempts")
        "COALESCE((SELECT SUM(#{total_cost}) FROM #{table} " \
          "WHERE #{attempts} < #{ActiveRecordInbox::MAX_ATTEMPTS} " \
          "AND #{tracked_at} BETWEEN #{connection.quote(start)} AND #{connection.quote(time)}), 0)"
      end

      def period_totals_table? = connection.data_source_exists?("llm_cost_tracker_period_totals")

      def range_start_for(period)
        utc_time = time.to_time.utc
        period == :monthly ? utc_time.beginning_of_month : utc_time.beginning_of_day
      end

      def bucket_for(period)
        utc_time = time.to_time.utc
        period == :monthly ? utc_time.beginning_of_month.to_date : utc_time.to_date
      end

      def connection = LlmCostTracker::LlmApiCall.connection
    end
  end
end
