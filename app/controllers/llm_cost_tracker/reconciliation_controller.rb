# frozen_string_literal: true

module LlmCostTracker
  class ReconciliationController < ApplicationController
    def index
      @reconciliation_enabled = LlmCostTracker::Reconciliation.enabled?
      @reconciliation_installed = LlmCostTracker::ProviderInvoice.table_exists?
      if @reconciliation_enabled && @reconciliation_installed
        @scopes = LlmCostTracker::Reconciliation.invoice_scopes
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
      if result.errors.any?
        LlmCostTracker::Logging.warn(
          "Reconciliation import for #{source} returned #{result.errors.size} row error(s)"
        )
        return redirect_to(
          reconciliation_path,
          alert: "Imported #{result.total_imported} #{source} rows " \
                 "with #{result.errors.size} row error(s); see Rails logs for details."
        )
      end
      redirect_to reconciliation_path,
                  notice: "Imported #{result.total_imported} #{source} rows"
    rescue StandardError => e
      LlmCostTracker::Logging.warn("Reconciliation import failed for #{source}: #{e.class}: #{e.message}")
      redirect_to reconciliation_path,
                  alert: "Import failed (#{e.class.name}); see Rails logs for details."
    end

    private

    def configured_importers
      LlmCostTracker.configuration.reconciliation_importers
    end

    def diff_for(scope)
      window = LlmCostTracker::Reconciliation
               .scope_relation(scope)
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
  end
end
