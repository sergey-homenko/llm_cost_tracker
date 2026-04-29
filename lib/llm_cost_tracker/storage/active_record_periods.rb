# frozen_string_literal: true

module LlmCostTracker
  module Storage
    module ActiveRecordPeriods
      PERIODS = {
        monthly: "month",
        daily:   "day"
      }.freeze

      module_function

      def valid_keys(periods)
        periods.map(&:to_sym).select { |period| PERIODS.key?(period) }
      end

      def range_start(period, time)
        utc_time = time.to_time.utc

        case period
        when :monthly then utc_time.beginning_of_month
        when :daily then utc_time.beginning_of_day
        end
      end

      def bucket(period, time)
        range_start(period, time).to_date
      end
    end
  end
end
