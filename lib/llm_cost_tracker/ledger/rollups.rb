# frozen_string_literal: true

require "bigdecimal"

require_relative "period_total"
require_relative "periods"
require_relative "rollups/batch"
require_relative "rollups/upsert_sql"

module LlmCostTracker
  class Ledger
    class Rollups
      class << self
        def reset!
          remove_instance_variable(:@period_totals_enabled) if instance_variable_defined?(:@period_totals_enabled)
        end

        def increment!(event)
          return unless event.total_cost
          return unless period_totals_enabled?

          LlmCostTracker::Ledger::PeriodTotal.upsert_all(
            period_rows(event),
            on_duplicate: Ledger::Rollups::UpsertSql.call(LlmCostTracker::Ledger::PeriodTotal),
            record_timestamps: true,
            unique_by: unique_by(LlmCostTracker::Ledger::PeriodTotal, %i[period period_start])
          )
        end

        def increment_many!(events)
          events = Array(events).select(&:total_cost)
          return if events.empty?
          return unless period_totals_enabled?

          LlmCostTracker::Ledger::PeriodTotal.upsert_all(
            Ledger::Rollups::Batch.rows(events),
            on_duplicate: Ledger::Rollups::UpsertSql.call(LlmCostTracker::Ledger::PeriodTotal),
            record_timestamps: true,
            unique_by: unique_by(LlmCostTracker::Ledger::PeriodTotal, %i[period period_start])
          )
        end

        def decrement!(call_rows)
          return unless period_totals_enabled?

          totals = period_decrement_totals(call_rows)
          return if totals.empty?

          apply_decrements(totals)
        end

        def period_totals(periods, time: Time.now.utc)
          periods = Ledger::Periods.valid_keys(periods)
          return {} if periods.empty?

          if period_totals_enabled?
            rollup_period_totals(periods, time)
          else
            periods.to_h { |period| [period, fallback_period_total(period, time)] }
          end
        end

        private

        def period_rows(event)
          Ledger::Periods::PERIODS.map do |period, name|
            {
              period: name,
              period_start: Ledger::Periods.bucket(period, event.tracked_at),
              total_cost: event.total_cost
            }
          end
        end

        def period_decrement_totals(call_rows)
          call_rows.each_with_object(Hash.new { |totals, key| totals[key] = BigDecimal("0") }) do |row, totals|
            _id, tracked_at, total_cost = row
            next unless total_cost

            Ledger::Periods::PERIODS.each_key do |period|
              totals[[period, Ledger::Periods.bucket(period, tracked_at)]] += BigDecimal(total_cost.to_s)
            end
          end
        end

        def apply_decrements(totals)
          now = Time.now.utc

          totals.each do |(period, period_start), amount|
            row = LlmCostTracker::Ledger::PeriodTotal.lock.find_by(period: Ledger::Periods::PERIODS.fetch(period),
                                                                   period_start: period_start)
            next unless row

            row.update_columns(total_cost: [BigDecimal(row.total_cost.to_s) - amount, BigDecimal("0")].max,
                               updated_at: now)
          end
        end

        def rollup_period_totals(periods, time)
          buckets = periods.to_h { |period| [period, Ledger::Periods.bucket(period, time)] }
          index = buckets.to_h { |period, bucket| [[Ledger::Periods::PERIODS.fetch(period), bucket], period] }
          totals = periods.to_h { |period| [period, 0.0] }

          LlmCostTracker::Ledger::PeriodTotal
            .where(period: periods.map { |period| Ledger::Periods::PERIODS.fetch(period) },
                   period_start: buckets.values)
            .select(:period, :period_start, :total_cost)
            .each do |row|
              period = index[[row.period, row.period_start.to_date]]
              totals[period] = row.total_cost.to_f if period
            end

          totals
        end

        def fallback_period_total(period, time)
          LlmCostTracker::Ledger::Call
            .where(tracked_at: Ledger::Periods.range_start(period, time)..time)
            .sum(:total_cost)
            .to_f
        end

        def period_totals_enabled?
          return @period_totals_enabled unless @period_totals_enabled.nil?

          @period_totals_enabled =
            LlmCostTracker::Ledger::Call.connection.data_source_exists?("llm_cost_tracker_period_totals")
        end

        def unique_by(model, column)
          return unless model.connection.supports_insert_conflict_target?

          column
        end
      end
    end
  end
end
