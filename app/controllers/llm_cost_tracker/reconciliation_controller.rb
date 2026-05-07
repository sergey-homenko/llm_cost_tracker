# frozen_string_literal: true

module LlmCostTracker
  class ReconciliationController < ApplicationController
    THRESHOLD_PERCENT = 5.0

    def index
      @sources = LlmCostTracker::ProviderInvoice
                 .order(:source)
                 .distinct
                 .pluck(:source)
      @diffs = @sources.map { |source| diff_for(source) }.compact
      @threshold = THRESHOLD_PERCENT
      @last_imported_at = LlmCostTracker::ProviderInvoice.maximum(:imported_at)
    end

    private

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
