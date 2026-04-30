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

          Period::Total.upsert_all(
            period_rows(event),
            on_duplicate: Ledger::Rollups::UpsertSql.call(Period::Total),
            record_timestamps: true,
            unique_by: unique_by(Period::Total, %i[period period_start])
          )
        end

        def increment_many!(events)
          events = Array(events).select(&:total_cost)
          return if events.empty?

          Period::Total.upsert_all(
            Ledger::Rollups::Batch.rows(events),
            on_duplicate: Ledger::Rollups::UpsertSql.call(Period::Total),
            record_timestamps: true,
            unique_by: unique_by(Period::Total, %i[period period_start])
          )
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
              totals[[period, Period.bucket(period, tracked_at)]] += BigDecimal(total_cost.to_s)
            end
          end
        end

        def apply_decrements(totals)
          now = Time.now.utc

          totals.each do |(period, period_start), amount|
            row = Period::Total.lock.find_by(period: Period::PERIODS.fetch(period),
                                             period_start: period_start)
            next unless row

            row.update_columns(total_cost: [BigDecimal(row.total_cost.to_s) - amount, BigDecimal("0")].max,
                               updated_at: now)
          end
        end

        def unique_by(model, column)
          return unless model.connection.supports_insert_conflict_target?

          column
        end
      end
    end
  end
end
