# frozen_string_literal: true

require "bigdecimal"

require_relative "active_record_periods"

module LlmCostTracker
  module Storage
    class ActiveRecordRollupBatch
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
          ActiveRecordPeriods::PERIODS.each do |period, name|
            rows[[name, ActiveRecordPeriods.bucket(period, event.tracked_at)]] += BigDecimal(event.cost.total_cost.to_s)
          end
        end
      end
    end
  end
end
