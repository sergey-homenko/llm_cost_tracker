# frozen_string_literal: true

require "json"

require_relative "ledger/schema/provider_invoices"
require_relative "ledger/schema/provider_invoice_imports"
require_relative "providers"
require_relative "reconciliation/import_result"
require_relative "reconciliation/importer"
require_relative "reconciliation/diff_result"
require_relative "reconciliation/diff"
require_relative "reconciliation/fingerprint"

module LlmCostTracker
  module Reconciliation
    DEFAULT_THRESHOLD_PERCENT = 5.0
    INVOICE_FRESHNESS_DAYS = 14
    SOURCE_TO_PROVIDER = {
      "openai" => "openai",
      "openai_usage" => "openai",
      "anthropic" => "anthropic",
      "anthropic_usage" => "anthropic",
      "gemini" => "gemini"
    }.freeze
    BASIS_DIMENSIONS = [
      ["project",   :provider_project_id],
      ["api_key",   :provider_api_key_id],
      ["workspace", :provider_workspace_id],
      ["model",     :model]
    ].freeze
    SCHEMA_TABLES = {
      Ledger::Schema::ProviderInvoices => "llm_cost_tracker_provider_invoices",
      Ledger::Schema::ProviderInvoiceImports => "llm_cost_tracker_provider_invoice_imports"
    }.freeze

    class << self
      def import(source:, rows:, provider: nil, imported_at: nil, window: nil,
                 strict_metadata: nil, cursor: nil)
        ensure_enabled!
        ensure_source_present!(source)
        Importer.new(
          source: source,
          provider: resolve_provider(source: source, provider: provider),
          imported_at: imported_at,
          window: window,
          strict_metadata: strict_metadata,
          cursor: cursor
        ).call(rows)
      end

      def diff(source:, period_start:, period_end:, provider: nil, scope: {}, currency: nil,
               drilldown_limit: Diff::DEFAULT_DRILLDOWN_LIMIT)
        ensure_enabled!
        ensure_source_present!(source)
        Diff.new(
          source: source,
          provider: resolve_provider(source: source, provider: provider),
          period_start: period_start,
          period_end: period_end,
          scope: scope,
          currency: currency,
          drilldown_limit: drilldown_limit
        ).call
      end

      def invoice_scopes
        provider_expr = Arel.sql(metadata_provider_sql)
        LlmCostTracker::ProviderInvoice
          .group(:source, provider_expr, :currency)
          .order(:source, :currency)
          .pluck(:source, provider_expr, :currency)
          .map { |source, provider, currency| { source: source, provider: provider, currency: currency.upcase } }
      end

      def scope_relation(scope)
        relation = LlmCostTracker::ProviderInvoice
                   .where(source: scope[:source], currency: scope[:currency])
        provider = scope[:provider]
        return relation if provider.nil? || provider.to_s.empty?

        relation.where("#{metadata_provider_sql} = ?", provider)
      end

      def ensure_source_present!(source)
        return unless source.to_s.empty?

        raise ArgumentError, "source must be present"
      end

      def resolve_provider(source:, provider:)
        return provider.to_s if provider

        mapped = SOURCE_TO_PROVIDER[source.to_s]
        return mapped if mapped

        recorded = recorded_provider_for(source)
        return recorded if recorded

        known = SOURCE_TO_PROVIDER.keys.join(", ")
        raise ArgumentError,
              "provider: must be specified for reconciliation source #{source.inspect}; " \
              "sources with a default provider mapping: #{known}"
      end

      def recorded_provider_for(source)
        return nil unless LlmCostTracker::ProviderInvoice.table_exists?

        metadata = LlmCostTracker::ProviderInvoice
                   .where(source: source.to_s)
                   .order(imported_at: :desc)
                   .limit(1)
                   .pick(:metadata)
        value = metadata_provider_value(metadata)
        value if value.is_a?(String) && !value.empty?
      end

      def metadata_provider_value(metadata)
        case metadata
        when Hash then metadata["provider"]
        when String
          parsed = JSON.parse(metadata) rescue nil # rubocop:disable Style/RescueModifier
          parsed.is_a?(Hash) ? parsed["provider"] : nil
        end
      end

      def enabled?
        LlmCostTracker.configuration.reconciliation_enabled
      end

      def ensure_enabled!
        return if enabled?

        raise Error,
              "reconciliation is disabled; set `config.reconciliation_enabled = true` in your initializer " \
              "(requires admin/org-level provider API keys; see docs/upgrading.md)"
      end

      private

      def metadata_provider_sql
        connection = LlmCostTracker::ProviderInvoice.connection
        if Ledger::Schema::Adapter.postgresql?(connection)
          "metadata->>'provider'"
        else
          "JSON_UNQUOTE(JSON_EXTRACT(metadata, '$.provider'))"
        end
      end
    end
  end
end
