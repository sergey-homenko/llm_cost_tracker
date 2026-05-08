# frozen_string_literal: true

require "bigdecimal"

require_relative "check"
require_relative "probe"
require_relative "../reconciliation"

module LlmCostTracker
  class Doctor
    class InvoiceReconciliationCheck
      def call
        return unless Reconciliation.enabled?
        return unless Probe.table_exists?("llm_cost_tracker_provider_invoices")
        return if no_imports?

        sources = imported_sources
        return Check.new(:ok, "invoice reconciliation", "no provider invoices imported yet") if sources.empty?

        sources.map { |source| check_source(source) }
      rescue StandardError => e
        Check.new(:error, "invoice reconciliation", e.message)
      end

      private

      def no_imports?
        LlmCostTracker::ProviderInvoice.none?
      end

      def threshold
        Reconciliation::DEFAULT_THRESHOLD_PERCENT
      end

      def imported_sources
        LlmCostTracker::ProviderInvoice.distinct.order(:source).pluck(:source)
      end

      def check_source(source)
        window = latest_window_for(source)
        return stale_check(source) if window.nil?

        diff = run_diff(source, window)
        return ok_check(source, window, diff) if diff.aligned?(threshold_percent: threshold)

        warn_check(source, window, diff)
      end

      def latest_window_for(source)
        latest = LlmCostTracker::ProviderInvoice
                 .where(source: source)
                 .select(:period_start, :period_end)
                 .order(period_end: :desc, period_start: :desc)
                 .limit(1)
                 .first
        return nil unless latest
        return nil if (Date.today - latest.period_end).to_i > Reconciliation::INVOICE_FRESHNESS_DAYS

        latest
      end

      def run_diff(source, window)
        Reconciliation.diff(
          source: source,
          period_start: window.period_start,
          period_end: window.period_end
        )
      end

      def stale_check(source)
        latest = LlmCostTracker::ProviderInvoice.where(source: source).maximum(:period_end)
        days = (Date.today - latest).to_i
        Check.new(
          :warn,
          "invoice reconciliation: #{source}",
          "no invoice imported in #{days} days (threshold #{Reconciliation::INVOICE_FRESHNESS_DAYS} days); " \
          "run reconciliation import"
        )
      end

      def ok_check(source, window, diff)
        Check.new(
          :ok,
          "invoice reconciliation: #{source}",
          "#{window.period_start}..#{window.period_end} aligned " \
          "(local=#{diff.local_total.to_s('F')}, provider=#{diff.provider_total.to_s('F')})"
        )
      end

      def warn_check(source, window, diff)
        Check.new(
          :warn,
          "invoice reconciliation: #{source}",
          "#{window.period_start}..#{window.period_end} drift " \
          "delta=#{diff.delta_amount.to_s('F')} (#{diff.delta_percent}%) " \
          "exceeds #{threshold}% threshold"
        )
      end
    end
  end
end
