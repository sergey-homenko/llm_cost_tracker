# frozen_string_literal: true

require "bigdecimal/util"

require_relative "period"

module LlmCostTracker
  module Ledger
    module Rollups
      class << self
        def cache_active?
          return false unless LlmCostTracker.configuration.budgets.totals_source == :cache
          return true if LlmCostTracker::CallRollup.table_exists?

          warn_missing_table
          false
        end

        def increment!(events)
          return unless cache_active?

          events = Array(events).select(&:total_cost)
          return if events.empty?

          LlmCostTracker::CallRollup.increment_all(period_rows_for_events(events))
        end

        ROLLUP_INCREMENT_ATTEMPTS = 3
        ROLLUP_INCREMENT_BASE_DELAY_SECONDS = 0.05
        REBUILD_INSERT_SLICE = 1_000
        private_constant :ROLLUP_INCREMENT_ATTEMPTS, :ROLLUP_INCREMENT_BASE_DELAY_SECONDS, :REBUILD_INSERT_SLICE

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
          return unless cache_active?

          buckets = bucket_totals(records)
          return if buckets.empty?

          LlmCostTracker::CallRollup.decrement(buckets)
        end

        def rebuild!
          accumulated = accumulate_priced_calls
          LlmCostTracker::CallRollup.transaction do
            LlmCostTracker::CallRollup.delete_all
            rows_from_buckets(accumulated).each_slice(REBUILD_INSERT_SLICE) do |rows|
              LlmCostTracker::CallRollup.increment_all(rows)
            end
          end
          accumulated.size
        end

        private

        def warn_missing_table
          return if @missing_table_warned

          @missing_table_warned = true
          Logging.warn(
            "config.budgets.totals_source = :cache is set but llm_cost_tracker_call_rollups is missing; " \
            "budget and dashboard totals fall back to aggregating llm_cost_tracker_calls. " \
            "Run the call_rollups generator and migrate, or set config.budgets.totals_source = :ledger."
          )
        end

        def accumulate_priced_calls
          accumulated = Hash.new { |totals, key| totals[key] = BigDecimal("0") }
          priced_calls.in_batches do |batch|
            bucket_totals(batch).each { |key, total| accumulated[key] += total }
          end
          accumulated
        end

        def priced_calls
          LlmCostTracker::Call.where.not(total_cost: nil)
                              .select(:id, :total_cost, :pricing_snapshot, :provider, :tracked_at)
        end

        def period_rows_for_events(events)
          rows_from_buckets(bucket_totals(events))
        end

        def rows_from_buckets(buckets)
          buckets.map do |(period, period_start, currency, provider), total_cost|
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
