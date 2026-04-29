# frozen_string_literal: true

require "bigdecimal"

module LlmCostTracker
  module Storage
    class ActiveRecordRollupBatch
      PERIODS = {
        monthly: "month",
        daily:   "day"
      }.freeze

      def self.rows(events)
        new(events).rows
      end

      def initialize(events)
        @events = events
      end

      def rows
        totals.map do |(period, period_start), total_cost|
          {
            period: period,
            period_start: period_start,
            total_cost: total_cost
          }
        end
      end

      private

      attr_reader :events

      def totals
        events.each_with_object(Hash.new { |hash, key| hash[key] = BigDecimal("0") }) do |event, rows|
          PERIODS.each do |period, name|
            rows[[name, bucket_for(period, event.tracked_at)]] += BigDecimal(event.cost.total_cost.to_s)
          end
        end
      end

      def bucket_for(period, time)
        utc_time = time.to_time.utc
        period == :monthly ? utc_time.beginning_of_month.to_date : utc_time.to_date
      end
    end
  end
end
