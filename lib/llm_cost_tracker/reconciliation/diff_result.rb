# frozen_string_literal: true

module LlmCostTracker
  module Reconciliation
    DiffResult = Data.define(
      :source,
      :period_start,
      :period_end,
      :currency,
      :scope,
      :provider_total,
      :local_total,
      :local_total_source,
      :delta_amount,
      :delta_percent,
      :unmatched_provider_rows,
      :unmatched_local_calls,
      :non_cost_rows
    ) do
      def aligned?(threshold_percent: Reconciliation::DEFAULT_THRESHOLD_PERCENT)
        return true if provider_total.zero? && local_total.zero?
        return false if delta_percent.nil?

        delta_percent.abs <= threshold_percent
      end

      def empty?
        provider_total.zero? && local_total.zero?
      end
    end
  end
end
