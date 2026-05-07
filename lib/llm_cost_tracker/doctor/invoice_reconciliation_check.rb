# frozen_string_literal: true

require "bigdecimal"

require_relative "check"
require_relative "probe"
require_relative "../reconciliation"

module LlmCostTracker
  class Doctor
    class InvoiceReconciliationCheck
      DEFAULT_THRESHOLD_PERCENT = 5.0
      FRESHNESS_DAYS = 14

      def call
        return unless Probe.table_exists?("llm_cost_tracker_provider_invoices")
        return Check.new(:ok, "invoice reconciliation", "no provider invoices imported yet") if no_imports?

        latest_window = latest_period_window
        return stale_check if latest_window.nil?

        diff = run_diff(latest_window)
        return ok_check(latest_window, diff) if diff.aligned?(threshold_percent: threshold)

        warn_check(latest_window, diff)
      rescue StandardError => e
        Check.new(:error, "invoice reconciliation", e.message)
      end

      private

      def no_imports?
        LlmCostTracker::ProviderInvoice.none?
      end

      def threshold
        DEFAULT_THRESHOLD_PERCENT
      end

      def latest_period_window
        latest = LlmCostTracker::ProviderInvoice
                 .select(:source, :period_start, :period_end)
                 .order(period_end: :desc, period_start: :desc)
                 .limit(1)
                 .first
        return nil unless latest
        return nil if (Date.today - latest.period_end).to_i > FRESHNESS_DAYS

        latest
      end

      def run_diff(window)
        Reconciliation.diff(
          source: window.source,
          period_start: window.period_start,
          period_end: window.period_end
        )
      end

      def stale_check
        latest = LlmCostTracker::ProviderInvoice.maximum(:period_end)
        days = (Date.today - latest).to_i
        Check.new(
          :warn,
          "invoice reconciliation",
          "no invoice imported in #{days} days (threshold #{FRESHNESS_DAYS} days); run reconciliation import"
        )
      end

      def ok_check(window, diff)
        Check.new(
          :ok,
          "invoice reconciliation",
          "#{window.source} #{window.period_start}..#{window.period_end} aligned " \
          "(local=#{diff.local_total.to_s('F')}, provider=#{diff.provider_total.to_s('F')})"
        )
      end

      def warn_check(window, diff)
        Check.new(
          :warn,
          "invoice reconciliation",
          "#{window.source} #{window.period_start}..#{window.period_end} drift " \
          "delta=#{diff.delta_amount.to_s('F')} (#{diff.delta_percent}%) " \
          "exceeds #{threshold}% threshold"
        )
      end
    end
  end
end
