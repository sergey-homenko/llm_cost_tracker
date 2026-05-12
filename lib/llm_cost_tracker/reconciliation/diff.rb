# frozen_string_literal: true

require "bigdecimal"
require "date"

require_relative "diff_result"
require_relative "../ledger/rollups"

module LlmCostTracker
  module Reconciliation
    class Diff # rubocop:disable Metrics/ClassLength
      SCOPE_KEYS = %i[provider_project_id provider_api_key_id provider_workspace_id].freeze
      ATTRIBUTION_KEYS = (SCOPE_KEYS + [:model]).freeze
      COST_ROW_TYPE = "cost"
      PERIOD_ONLY_BASIS = "period_only"
      BASIS_DIMENSION = {
        "project" => :provider_project_id,
        "api_key" => :provider_api_key_id,
        "workspace" => :provider_workspace_id,
        "model" => :model
      }.freeze

      DEFAULT_DRILLDOWN_LIMIT = 100

      def initialize(source:, period_start:, period_end:, provider:, scope: {}, currency: nil,
                     drilldown_limit: DEFAULT_DRILLDOWN_LIMIT)
        @source = source.to_s
        @provider = provider.to_s
        @period_start = parse_date(period_start)
        @period_end = parse_date(period_end)
        @scope = symbolize(scope || {}).slice(*SCOPE_KEYS)
        @currency = (currency || Ledger::Rollups::DEFAULT_CURRENCY).to_s
        @drilldown_limit = drilldown_limit
        raise ArgumentError, "source must be present" if @source.empty?
        raise ArgumentError, "provider must be present" if @provider.empty?
        raise ArgumentError, "period_end must be on or after period_start" if @period_end < @period_start
      end

      def call
        provider_total = scoped_invoices_relation_for(:cost, fully_contained: true)
                         .sum(:billed_amount)
                         .then { |sum| BigDecimal(sum.to_s) }
        cost_invoices = scoped_cost_invoices_for_drilldown
        non_cost_invoices = scoped_non_cost_invoices_for_drilldown
        local_calls = scoped_local_calls

        local_total, local_total_source = sum_local_total

        unmatched_providers_full = unmatched_provider_rows(cost_invoices, local_calls)
        unmatched_locals_full = unmatched_local_calls(cost_invoices, local_calls)
        non_cost_full = non_cost_invoices_to_rows(non_cost_invoices)

        DiffResult.new(
          source: source,
          provider: provider,
          period_start: period_start,
          period_end: period_end,
          currency: currency,
          scope: scope,
          provider_total: provider_total,
          local_total: local_total,
          local_total_source: local_total_source,
          delta_amount: local_total - provider_total,
          delta_percent: percent_for(local_total, provider_total),
          unmatched_provider_rows: cap_by_amount(unmatched_providers_full, :billed_amount),
          unmatched_provider_rows_total: unmatched_providers_full.size,
          unmatched_local_calls: cap_by_amount(unmatched_locals_full, :total_cost),
          unmatched_local_calls_total: unmatched_locals_full.size,
          non_cost_rows: cap_by_amount(non_cost_full, :billed_amount),
          non_cost_rows_total: non_cost_full.size
        )
      end

      private

      attr_reader :source, :provider, :period_start, :period_end, :scope, :currency

      def cap_by_amount(rows, key)
        return rows if @drilldown_limit.nil? || rows.size <= @drilldown_limit

        rows
          .sort_by { |row| -BigDecimal((row[key] || 0).to_s).abs }
          .first(@drilldown_limit)
      end

      def scoped_cost_invoices_for_drilldown
        relation = scoped_invoices_relation_for(:cost, fully_contained: true)
                   .order(billed_amount: :desc)
        relation = relation.limit(intermediate_load_limit) if intermediate_load_limit
        relation.to_a
      end

      def scoped_non_cost_invoices_for_drilldown
        connection = ProviderInvoice.connection
        relation =
          if Ledger::Schema::Adapter.postgresql?(connection)
            scoped_invoices_relation.where(
              "metadata->>'row_type' IS NOT NULL AND metadata->>'row_type' <> ?", COST_ROW_TYPE
            )
          else
            scoped_invoices_relation.where(
              "JSON_EXTRACT(metadata, '$.row_type') IS NOT NULL AND " \
              "JSON_UNQUOTE(JSON_EXTRACT(metadata, '$.row_type')) <> ?", COST_ROW_TYPE
            )
          end
        relation = relation.order(billed_amount: :desc)
        relation = relation.limit(intermediate_load_limit) if intermediate_load_limit
        relation.to_a
      end

      def intermediate_load_limit
        return nil if @drilldown_limit.nil?

        @drilldown_limit * 5
      end

      def scoped_invoices_relation_for(row_type_filter = nil, fully_contained: false)
        relation = scoped_invoices_relation
        relation = relation.where(period_start: period_start..).where(period_end: ..period_end) if fully_contained
        return relation unless row_type_filter == :cost

        connection = ProviderInvoice.connection
        if Ledger::Schema::Adapter.postgresql?(connection)
          relation.where(
            "metadata->>'row_type' IS NULL OR metadata->>'row_type' = ?", COST_ROW_TYPE
          )
        else
          relation.where(
            "JSON_EXTRACT(metadata, '$.row_type') IS NULL OR " \
            "JSON_UNQUOTE(JSON_EXTRACT(metadata, '$.row_type')) = ?", COST_ROW_TYPE
          )
        end
      end

      def scoped_invoices_relation
        relation = ProviderInvoice
                   .where(source: source, currency: currency)
                   .where(period_start: ..period_end)
                   .where(period_end: period_start..)
        relation = apply_metadata_scope(relation, "provider" => @provider)
        scope.empty? ? relation : apply_metadata_scope(relation, scope.transform_keys(&:to_s))
      end

      def apply_metadata_scope(relation, criteria)
        connection = ProviderInvoice.connection
        if Ledger::Schema::Adapter.postgresql?(connection)
          relation.where("metadata @> ?::jsonb", criteria.to_json)
        else
          criteria.inject(relation) do |chain, (key, value)|
            chain.where("JSON_UNQUOTE(JSON_EXTRACT(metadata, ?)) = ?", "$.#{key}", value.to_s)
          end
        end
      end

      def cost_row?(invoice)
        row_type = invoice.metadata["row_type"]
        row_type.nil? || row_type.to_s == COST_ROW_TYPE
      end

      def fully_contained?(invoice)
        invoice.period_start >= period_start && invoice.period_end <= period_end
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
        return [rollup_total, :rollups] if rollup_fast_path?

        [BigDecimal(scoped_line_items.sum(:cost).to_s), :line_items]
      end

      def rollup_fast_path?
        scope.empty? && month_aligned_period? &&
          LlmCostTracker.configuration.cache_rollups && LlmCostTracker::CallRollup.table_exists?
      end

      def month_aligned_period?
        period_start.day == 1 && (period_end + 1).day == 1 && period_end >= period_start
      end

      def rollup_total
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
                   .where("#{calls_table}.tracked_at" => window_start...window_end)
                   .where("#{calls_table}.provider" => provider)
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

      def non_cost_invoices_to_rows(invoices)
        invoices.map do |invoice|
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
        Time.utc(period_start.year, period_start.month, period_start.day)
      end

      def window_end
        next_day = period_end + 1
        Time.utc(next_day.year, next_day.month, next_day.day)
      end

      def percent_for(local, provider)
        return nil if provider.zero?

        ((local - provider) * 100 / provider).round(4).to_f
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
