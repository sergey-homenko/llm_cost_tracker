# frozen_string_literal: true

require "bigdecimal"
require "date"

require_relative "diff_result"
require_relative "../ledger/rollups"

module LlmCostTracker
  module Reconciliation
    class Diff
      SCOPE_KEYS = %i[provider_project_id provider_api_key_id provider_workspace_id].freeze
      ATTRIBUTION_KEYS = SCOPE_KEYS

      def initialize(source:, period_start:, period_end:, scope: {}, currency: nil)
        @source = source.to_s
        @period_start = parse_date(period_start)
        @period_end = parse_date(period_end)
        @scope = symbolize(scope || {}).slice(*SCOPE_KEYS)
        @currency = (currency || Ledger::Rollups::DEFAULT_CURRENCY).to_s
        raise ArgumentError, "source must be present" if @source.empty?
        raise ArgumentError, "period_end must be on or after period_start" if @period_end < @period_start
      end

      def call
        invoices = scoped_invoices
        local_calls = scoped_local_calls

        provider_total = sum_decimal(invoices.map(&:billed_amount))
        local_total = sum_decimal(local_calls.map { |row| row[:total_cost] })

        DiffResult.new(
          source: source,
          period_start: period_start,
          period_end: period_end,
          currency: currency,
          scope: scope,
          provider_total: provider_total,
          local_total: local_total,
          delta_amount: local_total - provider_total,
          delta_percent: percent_for(local_total, provider_total),
          unmatched_provider_rows: unmatched_provider_rows(invoices, local_calls),
          unmatched_local_calls: unmatched_local_calls(invoices, local_calls)
        )
      end

      private

      attr_reader :source, :period_start, :period_end, :scope, :currency

      def scoped_invoices
        relation = ProviderInvoice
                   .where(source: source, currency: currency)
                   .where(period_start: ..period_end)
                   .where(period_end: period_start..)
        return relation.to_a if scope.empty?

        relation.select { |invoice| scope_matches?(invoice.metadata) }
      end

      def scope_matches?(metadata)
        return false unless metadata.is_a?(Hash)

        scope.all? { |key, value| metadata[key.to_s].to_s == value.to_s }
      end

      def scoped_local_calls
        relation = LlmCostTracker::Call
                   .where.not(total_cost: nil)
                   .where(tracked_at: window_start..window_end)
        scope.each { |key, value| relation = relation.where(key => value) }
        attribution_columns = [:total_cost] + ATTRIBUTION_KEYS
        relation.pluck(*attribution_columns).map do |row|
          attrs = ATTRIBUTION_KEYS.zip(row.drop(1)).to_h
          { total_cost: row.first, attribution: attrs }
        end
      end

      def unmatched_provider_rows(invoices, local_calls)
        local_attribution = attribution_set(local_calls.map { |row| row[:attribution] })
        invoices.filter_map do |invoice|
          attribution = invoice_attribution(invoice).compact
          next if attribution.empty?
          next if local_attribution.include?(attribution)

          {
            external_id: invoice.external_id,
            billed_amount: invoice.billed_amount,
            attribution: attribution
          }
        end
      end

      def unmatched_local_calls(invoices, local_calls)
        invoice_attribution_set = attribution_set(invoices.map { |invoice| invoice_attribution(invoice) })
        grouped = local_calls.each_with_object({}) do |row, totals|
          attribution = row[:attribution].compact
          next if attribution.empty?
          next if invoice_attribution_set.include?(attribution)

          totals[attribution] ||= { count: 0, total_cost: BigDecimal("0") }
          totals[attribution][:count] += 1
          totals[attribution][:total_cost] += BigDecimal(row[:total_cost].to_s)
        end
        grouped.map { |attribution, summary| summary.merge(attribution: attribution) }
      end

      def invoice_attribution(invoice)
        metadata = invoice.metadata.is_a?(Hash) ? invoice.metadata : {}
        ATTRIBUTION_KEYS.to_h { |key| [key, metadata[key.to_s]] }
      end

      def attribution_set(attributions)
        attributions.map(&:compact).reject(&:empty?).to_set
      end

      def window_start
        period_start.to_time.utc
      end

      def window_end
        (period_end + 1).to_time.utc
      end

      def percent_for(local, provider)
        return nil if provider.zero?

        ((local - provider) * 100 / provider).round(4).to_f
      end

      def sum_decimal(values)
        values.compact.sum(BigDecimal("0")) { |value| BigDecimal(value.to_s) }
      end

      def symbolize(hash)
        hash.to_h.transform_keys { |key| key.to_s.to_sym }
      end

      def parse_date(value)
        return value if value.is_a?(Date)

        Date.parse(value.to_s)
      end
    end
  end
end
