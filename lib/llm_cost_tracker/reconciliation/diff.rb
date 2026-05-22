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
        @scope = (scope || {}).to_h.transform_keys { |key| key.to_s.to_sym }.slice(*SCOPE_KEYS)
        @currency = (currency || Ledger::Rollups::DEFAULT_CURRENCY).to_s.upcase
        @drilldown_limit = drilldown_limit
        raise ArgumentError, "source must be present" if @source.empty?
        raise ArgumentError, "provider must be present" if @provider.empty?
        raise ArgumentError, "period_end must be on or after period_start" if @period_end < @period_start
      end

      def call
        provider_total = scoped_cost_invoices_in_window
                         .sum(:billed_amount)
                         .then { |sum| BigDecimal(sum.to_s) }
        local_index = local_attribution_index_distinct
        invoice_basis_values = invoice_basis_values_distinct_sql

        local_total, local_total_source = sum_local_total

        unmatched_providers = unmatched_provider_rows_from_sql(local_index)
        unmatched_locals = unmatched_local_calls_in(invoice_basis_values)
        non_cost_rows = non_cost_invoices_to_rows(scoped_non_cost_invoices_for_drilldown)

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
          unmatched_provider_rows: cap_by_amount(unmatched_providers, :billed_amount),
          unmatched_provider_rows_total: unmatched_provider_rows_total_count(local_index),
          unmatched_local_calls: cap_by_amount(unmatched_locals, :total_cost),
          unmatched_local_calls_total: unmatched_local_calls_total_count(invoice_basis_values),
          non_cost_rows: cap_by_amount(non_cost_rows, :billed_amount),
          non_cost_rows_total: scoped_non_cost_invoices_relation.count
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

      def scoped_non_cost_invoices_for_drilldown
        relation = scoped_non_cost_invoices_relation.order(Arel.sql("ABS(billed_amount) DESC"))
        relation = relation.limit(@drilldown_limit) if @drilldown_limit
        relation.to_a
      end

      def scoped_cost_invoices_in_window
        relation = scoped_invoices_relation
                   .where(period_start: period_start..)
                   .where(period_end: ..period_end)

        connection = ProviderInvoice.connection
        if Ledger::Schema::Adapter.postgresql?(connection)
          relation.where(
            "metadata->>'row_type' IS NULL OR metadata->>'row_type' = ?", COST_ROW_TYPE
          )
        else
          relation.where(
            "JSON_EXTRACT(metadata, '$.row_type') IS NULL OR " \
            "JSON_TYPE(JSON_EXTRACT(metadata, '$.row_type')) = 'NULL' OR " \
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

      def sum_local_total
        return line_items_total unless rollup_fast_path?

        rollup = rollup_total
        return [rollup, :rollups] if rollup.positive?

        line_items_total
      end

      def line_items_total
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

      def unmatched_provider_rows_from_sql(local_index)
        rows = BASIS_DIMENSION.each_key.flat_map do |basis|
          column = BASIS_DIMENSION[basis].to_s
          relation = scoped_cost_invoices_in_window
          relation = where_match_basis_eq(relation, basis)
          relation = where_metadata_present(relation, column)
          values = local_index[basis].to_a
          relation = where_metadata_not_in(relation, column, values) if values.any?
          relation = relation.order(billed_amount: :desc)
          relation = relation.limit(@drilldown_limit) if @drilldown_limit
          relation.to_a.map { |invoice| build_unmatched_invoice_row(invoice, basis) }
        end
        rows.sort_by { |row| -BigDecimal((row[:billed_amount] || 0).to_s).abs }
      end

      def build_unmatched_invoice_row(invoice, basis)
        {
          external_id: invoice.external_id,
          billed_amount: invoice.billed_amount,
          attribution: invoice_attribution(invoice).compact,
          match_basis: basis
        }
      end

      def unmatched_provider_rows_total_count(local_index)
        BASIS_DIMENSION.each_key.sum do |basis|
          column = BASIS_DIMENSION[basis].to_s
          relation = scoped_cost_invoices_in_window
          relation = where_match_basis_eq(relation, basis)
          relation = where_metadata_present(relation, column)
          values = local_index[basis].to_a
          relation = where_metadata_not_in(relation, column, values) if values.any?
          relation.count
        end
      end

      def local_attribution_index_distinct
        BASIS_DIMENSION.each_key.to_h do |basis|
          column = BASIS_DIMENSION[basis]
          values = scoped_calls_relation.where.not(column => nil).distinct.pluck(column)
          [basis, Set.new(values)]
        end
      end

      def unmatched_local_calls_in(invoice_basis_values)
        grouped = scoped_line_items_with_attribution.each_with_object({}) do |row, totals|
          attribution = row[:attribution].compact
          next if attribution.empty?
          next if local_call_matched?(attribution, invoice_basis_values)

          totals[attribution] ||= { count: 0, total_cost: BigDecimal("0") }
          totals[attribution][:count] += 1
          totals[attribution][:total_cost] += BigDecimal(row[:total_cost].to_s)
        end
        grouped.map { |attribution, summary| summary.merge(attribution: attribution) }
      end

      def unmatched_local_calls_total_count(invoice_basis_values)
        unmatched = 0
        scoped_calls_relation.in_batches(of: 1_000) do |batch|
          batch.pluck(*ATTRIBUTION_KEYS).each do |row|
            attribution = ATTRIBUTION_KEYS.zip(row).each_with_object({}) do |(key, value), acc|
              acc[key] = value unless value.nil? || value.to_s.empty?
            end
            next if attribution.empty?
            next if local_call_matched?(attribution, invoice_basis_values)

            unmatched += 1
          end
        end
        unmatched
      end

      def invoice_basis_values_distinct_sql
        BASIS_DIMENSION.each_key.to_h do |basis|
          column = BASIS_DIMENSION[basis].to_s
          relation = scoped_cost_invoices_in_window
          relation = where_match_basis_eq(relation, basis)
          relation = where_metadata_present(relation, column)
          values = pluck_metadata_distinct(relation, column)
          [basis, Set.new(values)]
        end
      end

      def scoped_non_cost_invoices_relation
        connection = ProviderInvoice.connection
        if Ledger::Schema::Adapter.postgresql?(connection)
          scoped_invoices_relation.where(
            "metadata->>'row_type' IS NOT NULL AND metadata->>'row_type' <> ?", COST_ROW_TYPE
          )
        else
          scoped_invoices_relation.where(
            "JSON_EXTRACT(metadata, '$.row_type') IS NOT NULL AND " \
            "JSON_TYPE(JSON_EXTRACT(metadata, '$.row_type')) <> 'NULL' AND " \
            "JSON_UNQUOTE(JSON_EXTRACT(metadata, '$.row_type')) <> ?", COST_ROW_TYPE
          )
        end
      end

      def scoped_calls_relation
        line_items_table = LlmCostTracker::CallLineItem.quoted_table_name
        relation = LlmCostTracker::Call
                   .where(provider: provider)
                   .where(tracked_at: window_start...window_end)
                   .where(
                     "EXISTS (SELECT 1 FROM #{line_items_table} " \
                     "WHERE #{line_items_table}.llm_cost_tracker_call_id = #{calls_table}.id " \
                     "AND #{line_items_table}.currency = ?)",
                     currency
                   )
        scope.each { |key, value| relation = relation.where(key => value) }
        relation
      end

      def scoped_line_items_with_attribution
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

      def where_match_basis_eq(relation, basis)
        connection = ProviderInvoice.connection
        if Ledger::Schema::Adapter.postgresql?(connection)
          relation.where("metadata->>'match_basis' = ?", basis)
        else
          relation.where("JSON_UNQUOTE(JSON_EXTRACT(metadata, '$.match_basis')) = ?", basis)
        end
      end

      def where_metadata_present(relation, column)
        connection = ProviderInvoice.connection
        if Ledger::Schema::Adapter.postgresql?(connection)
          relation.where("metadata->>? IS NOT NULL", column)
        else
          relation.where("JSON_EXTRACT(metadata, ?) IS NOT NULL", "$.#{column}")
        end
      end

      def where_metadata_not_in(relation, column, values)
        connection = ProviderInvoice.connection
        if Ledger::Schema::Adapter.postgresql?(connection)
          relation.where.not("metadata->>? IN (?)", column, values)
        else
          relation.where.not("JSON_UNQUOTE(JSON_EXTRACT(metadata, ?)) IN (?)", "$.#{column}", values)
        end
      end

      def pluck_metadata_distinct(relation, column)
        connection = ProviderInvoice.connection
        expr =
          if Ledger::Schema::Adapter.postgresql?(connection)
            Arel.sql("metadata->>'#{column}'")
          else
            Arel.sql("JSON_UNQUOTE(JSON_EXTRACT(metadata, '$.#{column}'))")
          end
        relation.distinct.pluck(expr).compact
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

      def parse_date(value)
        return value if value.is_a?(Date)

        Date.parse(value.to_s)
      end
    end
  end
end
