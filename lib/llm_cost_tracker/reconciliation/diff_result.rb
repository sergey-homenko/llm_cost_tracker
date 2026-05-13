# frozen_string_literal: true

module LlmCostTracker
  module Reconciliation
    DiffResult = Data.define(
      :source,
      :provider,
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
      :unmatched_provider_rows_total,
      :unmatched_local_calls,
      :unmatched_local_calls_total,
      :non_cost_rows,
      :non_cost_rows_total
    ) do
      def unmatched_provider_rows_truncated?
        unmatched_provider_rows.size < unmatched_provider_rows_total
      end

      def unmatched_local_calls_truncated?
        unmatched_local_calls.size < unmatched_local_calls_total
      end

      def non_cost_rows_truncated?
        non_cost_rows.size < non_cost_rows_total
      end

      def aligned?(threshold_percent: Reconciliation::DEFAULT_THRESHOLD_PERCENT)
        return true if provider_total.zero? && local_total.zero?
        return false if delta_percent.nil?

        delta_percent.abs <= threshold_percent
      end
    end
  end
end
