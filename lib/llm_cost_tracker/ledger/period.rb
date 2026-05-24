# frozen_string_literal: true

module LlmCostTracker
  module Ledger
    module Period
      PERIODS = %i[month day].freeze

      def self.valid_keys(periods)
        PERIODS & periods
      end

      def self.range_start(period, time)
        utc_time = time.to_time.utc

        case period
        when :month then utc_time.beginning_of_month
        when :day then utc_time.beginning_of_day
        end
      end

      def self.bucket(period, time)
        range_start(period, time).to_date
      end
    end
  end
end
