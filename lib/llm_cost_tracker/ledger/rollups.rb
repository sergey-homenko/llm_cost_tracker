# frozen_string_literal: true

require "bigdecimal/util"

require_relative "period"

module LlmCostTracker
  module Ledger
    module Rollups
      class << self
        def increment!(events)
          events = Array(events).select(&:total_cost)
          return if events.empty?

          LlmCostTracker::CallRollup.increment_all(period_rows_for_events(events))
        end

        ROLLUP_INCREMENT_ATTEMPTS = 3
        ROLLUP_INCREMENT_BASE_DELAY_SECONDS = 0.05
        private_constant :ROLLUP_INCREMENT_ATTEMPTS, :ROLLUP_INCREMENT_BASE_DELAY_SECONDS

        def increment_safely!(events)
          attempt = 0
          begin
            attempt += 1
            increment!(events)
          rescue StandardError => e
            raise if LlmCostTracker::Call.connection.open_transactions.positive?

            if attempt < ROLLUP_INCREMENT_ATTEMPTS
              sleep(ROLLUP_INCREMENT_BASE_DELAY_SECONDS * (2**(attempt - 1)))
              retry
            end

            LlmCostTracker::Logging.warn(
              "Rollup increment failed for #{events.size} events after #{attempt} attempts: " \
              "#{e.class}: #{e.message}"
            )
          end
        end

        def decrement!(records)
          buckets = bucket_totals(records)
          return if buckets.empty?

          LlmCostTracker::CallRollup.decrement(buckets)
        end

        private

        def period_rows_for_events(events)
          bucket_totals(events).map do |(period, period_start, currency, provider), total_cost|
            {
              period: period,
              period_start: period_start,
              currency: currency,
              provider: provider,
              total_cost: total_cost
            }
          end
        end

        def bucket_totals(entries)
          entries.each_with_object(Hash.new { |totals, key| totals[key] = BigDecimal("0") }) do |entry, totals|
            next unless entry.total_cost

            currency = currency_from_snapshot(entry.pricing_snapshot)
            provider = entry.provider.to_s
            Period::PERIODS.each do |period|
              key = [period.to_s, Period.bucket(period, entry.tracked_at), currency, provider]
              totals[key] += entry.total_cost.to_d
            end
          end
        end

        def currency_from_snapshot(snapshot)
          value = (snapshot.is_a?(Hash) && snapshot["currency"]) || LlmCostTracker::DEFAULT_CURRENCY
          value.to_s.upcase
        end
      end
    end
  end
end
