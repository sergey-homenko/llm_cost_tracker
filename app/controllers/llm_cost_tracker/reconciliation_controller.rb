# frozen_string_literal: true

module LlmCostTracker
  class ReconciliationController < ApplicationController
    def index
      @reconciliation_enabled = LlmCostTracker::Reconciliation.enabled?
      @reconciliation_installed = LlmCostTracker::ProviderInvoice.table_exists?
      if @reconciliation_enabled && @reconciliation_installed
        @scopes = invoice_scopes
        @sources = @scopes.map { |scope| scope[:source] }.uniq
        @diffs = @scopes.filter_map { |scope| diff_for(scope) }
        @last_imported_at = LlmCostTracker::ProviderInvoice.maximum(:imported_at)
      else
        @scopes = []
        @sources = []
        @diffs = []
        @last_imported_at = nil
      end
      @threshold = LlmCostTracker::Reconciliation::DEFAULT_THRESHOLD_PERCENT
      @configured_importers = @reconciliation_enabled ? configured_importers : {}
    end

    def trigger_import
      unless LlmCostTracker::Reconciliation.enabled?
        return redirect_to reconciliation_path, alert: "Reconciliation is disabled"
      end

      source = params[:source].to_s
      importer = configured_importers[source.to_sym]
      return redirect_to reconciliation_path, alert: "No importer configured for #{source}" if importer.nil?

      result = importer.call
      if result.respond_to?(:errors) && result.errors.any?
        LlmCostTracker::Logging.warn(
          "Reconciliation import for #{source} returned #{result.errors.size} row error(s)"
        )
        return redirect_to(
          reconciliation_path,
          alert: "Imported #{result.respond_to?(:total_imported) ? result.total_imported : 0} " \
                 "#{source} rows with #{result.errors.size} row error(s); see Rails logs for details."
        )
      end
      message = if result.respond_to?(:total_imported)
                  "Imported #{result.total_imported} #{source} rows"
                else
                  "Triggered #{source} importer"
                end
      redirect_to reconciliation_path, notice: message
    rescue StandardError => e
      LlmCostTracker::Logging.warn("Reconciliation import failed for #{source}: #{e.class}: #{e.message}")
      redirect_to reconciliation_path,
                  alert: "Import failed (#{e.class.name}); see Rails logs for details."
    end

    private

    def configured_importers
      LlmCostTracker.configuration.reconciliation_importers
    end

    def invoice_scopes
      connection = LlmCostTracker::ProviderInvoice.connection
      provider_expr =
        if LlmCostTracker::Ledger::Schema::Adapter.postgresql?(connection)
          Arel.sql("metadata->>'provider'")
        else
          Arel.sql("JSON_UNQUOTE(JSON_EXTRACT(metadata, '$.provider'))")
        end
      LlmCostTracker::ProviderInvoice
        .group(:source, provider_expr, :currency)
        .order(:source, :currency)
        .pluck(:source, provider_expr, :currency)
        .map { |source, provider, currency| { source: source, provider: provider, currency: currency } }
    end

    def diff_for(scope)
      window = scope_invoices(scope)
               .order(period_end: :desc, period_start: :desc)
               .limit(1)
               .pick(:period_start, :period_end)
      return nil unless window

      LlmCostTracker::Reconciliation.diff(
        source: scope[:source], provider: scope[:provider], currency: scope[:currency],
        period_start: window[0], period_end: window[1]
      )
    rescue ArgumentError => e
      LlmCostTracker::Logging.warn("Reconciliation diff skipped for #{scope.inspect}: #{e.message}")
      nil
    end

    def scope_invoices(scope)
      relation = LlmCostTracker::ProviderInvoice
                 .where(source: scope[:source], currency: scope[:currency])
      connection = LlmCostTracker::ProviderInvoice.connection
      provider = scope[:provider]
      return relation if provider.nil? || provider.empty?

      if LlmCostTracker::Ledger::Schema::Adapter.postgresql?(connection)
        relation.where("metadata->>'provider' = ?", provider)
      else
        relation.where("JSON_UNQUOTE(JSON_EXTRACT(metadata, '$.provider')) = ?", provider)
      end
    end
  end
end
