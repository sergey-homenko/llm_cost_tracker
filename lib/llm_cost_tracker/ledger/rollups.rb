# frozen_string_literal: true

require "bigdecimal/util"

require_relative "period"
require_relative "rollups/upsert_sql"

module LlmCostTracker
  module Ledger
    class Rollups
      class << self
        def increment!(events)
          events = Array(events).select(&:total_cost)
          return if events.empty?

          upsert_call_rollups(period_rows_for_events(events))
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
          buckets = period_decrement_totals(records)
          return if buckets.empty?

          LlmCostTracker::CallRollup.decrement(buckets)
        end

        private

        def period_rows_for_events(events)
          period_increment_totals(events).map do |(period, period_start, currency, provider), total_cost|
            {
              period: period,
              period_start: period_start,
              currency: currency,
              provider: provider,
              total_cost: total_cost
            }
          end
        end

        def period_increment_totals(events)
          events.each_with_object(Hash.new { |totals, key| totals[key] = BigDecimal("0") }) do |event, totals|
            currency = currency_from_snapshot(event.pricing_snapshot)
            provider = event.provider.to_s
            Period::PERIODS.each do |period|
              key = [period.to_s, Period.bucket(period, event.tracked_at), currency, provider]
              totals[key] += event.total_cost.to_d
            end
          end
        end

        def period_decrement_totals(records)
          records.each_with_object(Hash.new { |totals, key| totals[key] = BigDecimal("0") }) do |record, totals|
            next unless record.total_cost

            currency = currency_from_snapshot(record.pricing_snapshot)
            provider = record.provider.to_s
            Period::PERIODS.each do |period|
              key = [period.to_s, Period.bucket(period, record.tracked_at), currency, provider]
              totals[key] += record.total_cost.to_d
            end
          end
        end

        def currency_from_snapshot(snapshot)
          value = (snapshot.is_a?(Hash) && snapshot["currency"]) || LlmCostTracker::DEFAULT_CURRENCY
          value.to_s.upcase
        end

        def upsert_call_rollups(rows)
          LlmCostTracker::CallRollup.upsert_all(
            rows,
            on_duplicate: Ledger::Rollups::UpsertSql.call,
            record_timestamps: true,
            unique_by: call_rollups_unique_by
          )
        end

        def call_rollups_unique_by
          return unless LlmCostTracker::CallRollup.connection.supports_insert_conflict_target?

          %i[period period_start currency provider]
        end
      end
    end
  end
end
