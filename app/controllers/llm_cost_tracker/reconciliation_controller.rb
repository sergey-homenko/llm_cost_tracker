# frozen_string_literal: true

module LlmCostTracker
  class ReconciliationController < ApplicationController
    def index
      @sources = LlmCostTracker::ProviderInvoice
                 .order(:source)
                 .distinct
                 .pluck(:source)
      @diffs = @sources.map { |source| diff_for(source) }.compact
      @threshold = LlmCostTracker::Reconciliation::DEFAULT_THRESHOLD_PERCENT
      @last_imported_at = LlmCostTracker::ProviderInvoice.maximum(:imported_at)
      @configured_importers = configured_importers
    end

    def trigger_import
      source = params[:source].to_s
      importer = configured_importers[source.to_sym]
      return redirect_to reconciliation_path, alert: "No importer configured for #{source}" if importer.nil?

      result = importer.call
      message = if result.respond_to?(:total_imported)
                  "Imported #{result.total_imported} #{source} rows"
                else
                  "Triggered #{source} importer"
                end
      redirect_to reconciliation_path, notice: message
    rescue StandardError => e
      redirect_to reconciliation_path, alert: "Import failed: #{e.message}"
    end

    private

    def configured_importers
      LlmCostTracker.configuration.reconciliation_importers
    end

    def diff_for(source)
      window = LlmCostTracker::ProviderInvoice
               .where(source: source)
               .order(period_end: :desc, period_start: :desc)
               .limit(1)
               .pick(:period_start, :period_end)
      return nil unless window

      LlmCostTracker::Reconciliation.diff(
        source: source, period_start: window[0], period_end: window[1]
      )
    end
  end
end
