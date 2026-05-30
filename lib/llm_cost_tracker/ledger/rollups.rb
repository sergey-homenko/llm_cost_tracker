# frozen_string_literal: true

require "bigdecimal"

require_relative "period"
require_relative "rollups/upsert_sql"

module LlmCostTracker
  module Ledger
    class Rollups
      DECREMENT_COLUMNS = %i[id tracked_at total_cost pricing_snapshot provider].freeze

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

        def decrement!(call_rows)
          totals = period_decrement_totals(call_rows)
          return if totals.empty?

          apply_decrements(totals)
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
              totals[key] += BigDecimal(event.total_cost.to_s)
            end
          end
        end

        def period_decrement_totals(call_rows)
          call_rows.each_with_object(Hash.new { |totals, key| totals[key] = BigDecimal("0") }) do |columns, totals|
            row = DECREMENT_COLUMNS.zip(columns).to_h
            next unless row[:total_cost]

            currency = currency_from_snapshot(row[:pricing_snapshot])
            provider_key = row[:provider].to_s
            Period::PERIODS.each do |period|
              totals[[period, Period.bucket(period, row[:tracked_at]), currency, provider_key]] += row[:total_cost]
            end
          end
        end

        def apply_decrements(totals)
          now = Time.now.utc
          buckets_by_period = totals.each_with_object({}) do |(key, amount), grouped|
            period, period_start, currency, provider = key
            grouped[[period, currency, provider]] ||= {}
            grouped[[period, currency, provider]][period_start] = amount
          end

          conn = LlmCostTracker::CallRollup.connection
          table = LlmCostTracker::CallRollup.quoted_table_name
          period_col = conn.quote_column_name("period")
          start_col = conn.quote_column_name("period_start")
          currency_col = conn.quote_column_name("currency")
          provider_col = conn.quote_column_name("provider")
          total_col = conn.quote_column_name("total_cost")
          updated_col = conn.quote_column_name("updated_at")

          buckets_by_period.each do |(period, currency, provider), by_start|
            case_clauses = by_start.map do |period_start, amount|
              "WHEN #{start_col} = #{conn.quote(period_start)} THEN #{conn.quote(amount)}"
            end.join(" ")
            starts = by_start.keys.map { |period_start| conn.quote(period_start) }.join(", ")

            conn.execute(
              "UPDATE #{table} " \
              "SET #{total_col} = GREATEST(0, #{total_col} - CASE #{case_clauses} ELSE 0 END), " \
              "#{updated_col} = #{conn.quote(now)} " \
              "WHERE #{period_col} = #{conn.quote(period.to_s)} " \
              "AND #{currency_col} = #{conn.quote(currency)} " \
              "AND #{provider_col} = #{conn.quote(provider)} " \
              "AND #{start_col} IN (#{starts})"
            )
          end
        end

        def currency_from_snapshot(snapshot)
          value = (snapshot.is_a?(Hash) && snapshot["currency"]) || Billing::DEFAULT_CURRENCY
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
