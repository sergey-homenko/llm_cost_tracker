# frozen_string_literal: true

require "bigdecimal"

require_relative "period"
require_relative "rollups/upsert_sql"

module LlmCostTracker
  module Ledger
    class Rollups
      class << self
        def increment_many!(events)
          events = Array(events).select(&:total_cost)
          return if events.empty?

          upsert_call_rollups(period_rows_for_events(events))
        end

        def decrement!(call_rows)
          totals = period_decrement_totals(call_rows)
          return if totals.empty?

          apply_decrements(totals)
        end

        private

        def period_rows_for_events(events)
          call_rollups(events).map do |(period, period_start, currency, provider), total_cost|
            {
              period: period,
              period_start: period_start,
              currency: currency,
              provider: provider,
              total_cost: total_cost
            }
          end
        end

        def call_rollups(events)
          events.each_with_object(Hash.new { |totals, key| totals[key] = BigDecimal("0") }) do |event, totals|
            currency = currency_from_snapshot(event.pricing_snapshot)
            provider = event.provider.to_s
            Period::PERIODS.each do |period, name|
              key = [name, Period.bucket(period, event.tracked_at), currency, provider]
              totals[key] += BigDecimal(event.total_cost.to_s)
            end
          end
        end

        def period_decrement_totals(call_rows)
          call_rows.each_with_object(Hash.new { |totals, key| totals[key] = BigDecimal("0") }) do |row, totals|
            _id, tracked_at, total_cost, pricing_snapshot, provider = row
            next unless total_cost

            currency = currency_from_snapshot(pricing_snapshot)
            provider_key = provider.to_s
            Period::PERIODS.each_key do |period|
              totals[[period, Period.bucket(period, tracked_at), currency, provider_key]] += total_cost
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
              "WHERE #{period_col} = #{conn.quote(Period::PERIODS.fetch(period))} " \
              "AND #{currency_col} = #{conn.quote(currency)} " \
              "AND #{provider_col} = #{conn.quote(provider)} " \
              "AND #{start_col} IN (#{starts})"
            )
          end
        end

        def currency_from_snapshot(snapshot)
          value = (snapshot.is_a?(Hash) && (snapshot["currency"] || snapshot[:currency])) || Billing::DEFAULT_CURRENCY
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
