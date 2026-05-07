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
      COST_ROW_TYPE = "cost"
      PERIOD_ONLY_BASIS = "period_only"
      SOURCE_TO_PROVIDER = {
        "openai" => "openai",
        "anthropic" => "anthropic",
        "gemini" => "gemini"
      }.freeze
      BASIS_DIMENSION = {
        "project" => :provider_project_id,
        "api_key" => :provider_api_key_id,
        "workspace" => :provider_workspace_id
      }.freeze

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
        cost_invoices = invoices.select { |invoice| cost_row?(invoice) }
        local_calls = scoped_local_calls

        provider_total = sum_decimal(cost_invoices.map(&:billed_amount))
        local_total = sum_local_total

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
          unmatched_provider_rows: unmatched_provider_rows(cost_invoices, local_calls),
          unmatched_local_calls: unmatched_local_calls(cost_invoices, local_calls),
          non_cost_rows: non_cost_rows(invoices)
        )
      end

      private

      attr_reader :source, :period_start, :period_end, :scope, :currency

      def scoped_invoices
        relation = ProviderInvoice
                   .where(source: source, currency: currency)
                   .where(period_start: ..period_end)
                   .where(period_end: period_start..)
        relation = apply_metadata_scope(relation) unless scope.empty?
        relation.to_a
      end

      def apply_metadata_scope(relation)
        connection = ProviderInvoice.connection
        if Ledger::Schema::Adapter.postgresql?(connection)
          relation.where("metadata @> ?::jsonb", scope.transform_keys(&:to_s).to_json)
        else
          scope.inject(relation) do |chain, (key, value)|
            chain.where("JSON_EXTRACT(metadata, ?) = ?", "$.#{key}", value.to_s)
          end
        end
      end

      def cost_row?(invoice)
        row_type = invoice.metadata["row_type"]
        row_type.nil? || row_type.to_s == COST_ROW_TYPE
      end

      def scoped_local_calls
        attribution_columns = ATTRIBUTION_KEYS.map { |key| "#{calls_table}.#{key}" }
        call_id = "#{calls_table}.id"
        rows = scoped_line_items
               .group(call_id, *attribution_columns)
               .pluck(call_id, Arel.sql("SUM(cost)"), *attribution_columns)
        rows.map do |row|
          _id, total_cost, *attrs = row
          { total_cost: total_cost, attribution: ATTRIBUTION_KEYS.zip(attrs).to_h }
        end
      end

      def sum_local_total
        return rollup_total if rollup_fast_path?

        BigDecimal(scoped_line_items.sum(:cost).to_s)
      end

      def rollup_fast_path?
        scope.empty? && SOURCE_TO_PROVIDER.key?(source) && month_aligned_period?
      end

      def month_aligned_period?
        period_start.day == 1 && (period_end + 1).day == 1 && period_end >= period_start
      end

      def rollup_total
        provider = SOURCE_TO_PROVIDER[source]
        cursor = period_start
        buckets = []
        while cursor <= period_end
          buckets << cursor
          cursor = cursor.next_month
        end
        relation = LlmCostTracker::CallRollup
                   .where(period: "month", currency: currency, provider: provider)
                   .where(period_start: buckets)
        BigDecimal(relation.sum(:total_cost).to_s)
      end

      def scoped_line_items
        relation = LlmCostTracker::CallLineItem
                   .joins(:call)
                   .where(llm_cost_tracker_call_line_items: { currency: currency })
                   .where("#{calls_table}.tracked_at" => window_start..window_end)
        provider = SOURCE_TO_PROVIDER[source]
        relation = relation.where("#{calls_table}.provider" => provider) if provider
        scope.each { |key, value| relation = relation.where("#{calls_table}.#{key}" => value) }
        relation
      end

      def calls_table
        LlmCostTracker::Call.quoted_table_name
      end

      def unmatched_provider_rows(invoices, local_calls)
        local_index = local_attribution_index(local_calls)
        invoices.filter_map do |invoice|
          basis = invoice_match_basis(invoice)
          next if basis == PERIOD_ONLY_BASIS

          invoice_value = invoice.metadata[BASIS_DIMENSION[basis].to_s]
          next if invoice_value.nil?
          next if local_index[basis].include?(invoice_value)

          {
            external_id: invoice.external_id,
            billed_amount: invoice.billed_amount,
            attribution: invoice_attribution(invoice).compact,
            match_basis: basis
          }
        end
      end

      def local_attribution_index(local_calls)
        index = BASIS_DIMENSION.each_key.to_h { |basis| [basis, Set.new] }
        local_calls.each do |call|
          BASIS_DIMENSION.each do |basis, key|
            value = call[:attribution][key]
            index[basis] << value if value
          end
        end
        index
      end

      def unmatched_local_calls(invoices, local_calls)
        basis_values = invoice_basis_values(invoices)
        grouped = local_calls.each_with_object({}) do |row, totals|
          attribution = row[:attribution].compact
          next if attribution.empty?
          next if local_call_matched?(attribution, basis_values)

          totals[attribution] ||= { count: 0, total_cost: BigDecimal("0") }
          totals[attribution][:count] += 1
          totals[attribution][:total_cost] += BigDecimal(row[:total_cost].to_s)
        end
        grouped.map { |attribution, summary| summary.merge(attribution: attribution) }
      end

      def invoice_match_basis(invoice)
        declared = invoice.metadata["match_basis"]
        return declared if BASIS_DIMENSION.key?(declared)
        return declared if declared == PERIOD_ONLY_BASIS

        BASIS_DIMENSION.each do |basis, dimension|
          return basis if invoice.metadata[dimension.to_s]
        end
        PERIOD_ONLY_BASIS
      end

      def invoice_basis_values(invoices)
        index = BASIS_DIMENSION.each_key.to_h { |basis| [basis, Set.new] }
        invoices.each do |invoice|
          basis = invoice_match_basis(invoice)
          next unless BASIS_DIMENSION.key?(basis)

          value = invoice.metadata[BASIS_DIMENSION[basis].to_s]
          index[basis] << value if value
        end
        index
      end

      def local_call_matched?(attribution, basis_values)
        BASIS_DIMENSION.any? do |basis, local_key|
          value = attribution[local_key]
          value && basis_values[basis].include?(value)
        end
      end

      def non_cost_rows(invoices)
        invoices.reject { |invoice| cost_row?(invoice) }.map do |invoice|
          {
            external_id: invoice.external_id,
            row_type: invoice.metadata["row_type"],
            meter: invoice.metadata["meter"],
            billed_amount: invoice.billed_amount,
            attribution: invoice_attribution(invoice).compact,
            match_basis: invoice_match_basis(invoice)
          }
        end
      end

      def invoice_attribution(invoice)
        ATTRIBUTION_KEYS.to_h { |key| [key, invoice.metadata[key.to_s]] }
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
