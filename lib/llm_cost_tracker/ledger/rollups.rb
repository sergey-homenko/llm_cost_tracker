# frozen_string_literal: true

require "bigdecimal"

require_relative "period"
require_relative "rollups/batch"
require_relative "rollups/upsert_sql"

module LlmCostTracker
  module Ledger
    class Rollups
      class << self
        def increment!(event)
          return unless event.total_cost

          upsert_period_totals(period_rows(event))
        end

        def increment_many!(events)
          events = Array(events).select(&:total_cost)
          return if events.empty?

          upsert_period_totals(Ledger::Rollups::Batch.rows(events))
        end

        def decrement!(call_rows)
          totals = period_decrement_totals(call_rows)
          return if totals.empty?

          apply_decrements(totals)
        end

        private

        def period_rows(event)
          Period::PERIODS.map do |period, name|
            {
              period: name,
              period_start: Period.bucket(period, event.tracked_at),
              total_cost: event.total_cost
            }
          end
        end

        def period_decrement_totals(call_rows)
          call_rows.each_with_object(Hash.new { |totals, key| totals[key] = BigDecimal("0") }) do |row, totals|
            _id, tracked_at, total_cost = row
            next unless total_cost

            Period::PERIODS.each_key do |period|
              totals[[period, Period.bucket(period, tracked_at)]] += total_cost
            end
          end
        end

        def apply_decrements(totals)
          now = Time.now.utc

          totals.each do |(period, period_start), amount|
            row = Period::Total.lock.find_by(period: Period::PERIODS.fetch(period),
                                             period_start: period_start)
            next unless row

            row.update_columns(total_cost: [row.total_cost - amount, BigDecimal("0")].max,
                               updated_at: now)
          end
        end

        def upsert_period_totals(rows)
          Period::Total.upsert_all(
            rows,
            on_duplicate: Ledger::Rollups::UpsertSql.call,
            record_timestamps: true,
            unique_by: period_totals_unique_by
          )
        end

        def period_totals_unique_by
          return unless Period::Total.connection.supports_insert_conflict_target?

          %i[period period_start]
        end
      end
    end
  end
end
