# frozen_string_literal: true

require "bigdecimal"

require_relative "check"
require_relative "probe"
require_relative "../ledger/schema/adapter"

module LlmCostTracker
  class Doctor
    class InvoiceReconciliationCheck
      def call
        return unless LlmCostTracker.reconciliation_enabled?
        return unless Probe.table_exists?("llm_cost_tracker_provider_invoices")
        return if no_imports?

        scopes = imported_scopes
        return Check.new(:ok, "invoice reconciliation", "no provider invoices imported yet") if scopes.empty?

        non_canonical = non_canonical_currency_check
        checks = scopes.map { |scope| check_scope_safely(scope) }
        checks << non_canonical if non_canonical
        checks
      rescue StandardError => e
        Check.new(:error, "invoice reconciliation", e.message)
      end

      private

      def no_imports?
        LlmCostTracker::ProviderInvoice.none?
      end

      def non_canonical_currency_check
        legacy = LlmCostTracker::ProviderInvoice.where("currency <> UPPER(currency)").count
        return nil if legacy.zero?

        Check.new(
          :warn,
          "invoice reconciliation: currency canonicalisation",
          "#{legacy} provider invoice row(s) stored with non-uppercase currency. Diff queries " \
          "are case-sensitive — run " \
          "`UPDATE llm_cost_tracker_provider_invoices SET currency = UPPER(currency);` to backfill."
        )
      end

      def threshold
        Reconciliation::DEFAULT_THRESHOLD_PERCENT
      end

      def imported_scopes
        connection = LlmCostTracker::ProviderInvoice.connection
        provider_expr =
          if Ledger::Schema::Adapter.postgresql?(connection)
            Arel.sql("metadata->>'provider'")
          else
            Arel.sql("JSON_UNQUOTE(JSON_EXTRACT(metadata, '$.provider'))")
          end
        LlmCostTracker::ProviderInvoice
          .group(:source, provider_expr, :currency)
          .order(:source, :currency)
          .pluck(:source, provider_expr, :currency)
          .map { |source, provider, currency| { source: source, provider: provider, currency: currency.upcase } }
      end

      def scope_label(scope)
        "#{scope[:source]}/#{scope[:provider]}/#{scope[:currency]}"
      end

      def check_scope_safely(scope)
        check_scope(scope)
      rescue ArgumentError => e
        Check.new(:warn, "invoice reconciliation: #{scope_label(scope)}", e.message)
      end

      def check_scope(scope)
        window = latest_window_for(scope)
        return stale_check(scope) if window.nil?

        diff = run_diff(scope, window)
        return ok_check(scope, window, diff) if diff.aligned?(threshold_percent: threshold)

        warn_check(scope, window, diff)
      end

      def scope_relation(scope)
        relation = LlmCostTracker::ProviderInvoice
                   .where(source: scope[:source], currency: scope[:currency])
        provider = scope[:provider]
        return relation if provider.nil? || provider.to_s.empty?

        connection = LlmCostTracker::ProviderInvoice.connection
        if Ledger::Schema::Adapter.postgresql?(connection)
          relation.where("metadata->>'provider' = ?", provider)
        else
          relation.where("JSON_UNQUOTE(JSON_EXTRACT(metadata, '$.provider')) = ?", provider)
        end
      end

      def latest_window_for(scope)
        latest = scope_relation(scope)
                 .select(:period_start, :period_end)
                 .order(period_end: :desc, period_start: :desc)
                 .limit(1)
                 .first
        return nil unless latest
        return nil if (Time.now.utc.to_date - latest.period_end).to_i > Reconciliation::INVOICE_FRESHNESS_DAYS

        latest
      end

      def run_diff(scope, window)
        Reconciliation.diff(
          source: scope[:source],
          provider: scope[:provider],
          currency: scope[:currency],
          period_start: window.period_start,
          period_end: window.period_end
        )
      end

      def stale_check(scope)
        latest = scope_relation(scope).maximum(:period_end)
        return scope_unreachable_check(scope) if latest.nil?

        days = (Time.now.utc.to_date - latest).to_i
        Check.new(
          :warn,
          "invoice reconciliation: #{scope_label(scope)}",
          "no invoice imported in #{days} days (threshold #{Reconciliation::INVOICE_FRESHNESS_DAYS} days); " \
          "run reconciliation import"
        )
      end

      def scope_unreachable_check(scope)
        Check.new(
          :warn,
          "invoice reconciliation: #{scope_label(scope)}",
          "scope grouped invoices but the filter (likely currency case mismatch) matches zero rows; " \
          "the currency-canonicalisation check below points at the backfill SQL"
        )
      end

      def ok_check(scope, window, diff)
        Check.new(
          :ok,
          "invoice reconciliation: #{scope_label(scope)}",
          "#{window.period_start}..#{window.period_end} aligned " \
          "(local=#{diff.local_total.to_s('F')}, provider=#{diff.provider_total.to_s('F')})"
        )
      end

      def warn_check(scope, window, diff)
        Check.new(
          :warn,
          "invoice reconciliation: #{scope_label(scope)}",
          "#{window.period_start}..#{window.period_end} drift " \
          "delta=#{diff.delta_amount.to_s('F')} (#{diff.delta_percent}%) " \
          "exceeds #{threshold}% threshold"
        )
      end
    end
  end
end
