# frozen_string_literal: true

require_relative "ledger"
require_relative "doctor/check"
require_relative "doctor/probe"
require_relative "doctor/ingestion_check"
require_relative "doctor/legacy_audit_check"
require_relative "doctor/legacy_billing_status_check"
require_relative "doctor/price_check"
require_relative "doctor/schema_check"
require_relative "doctor/cost_drift_check"
require_relative "doctor/pricing_snapshot_drift_check"

module LlmCostTracker
  class Doctor
    autoload :InvoiceReconciliationCheck, "llm_cost_tracker/doctor/invoice_reconciliation_check"
    autoload :CaptureVerifier,            "llm_cost_tracker/doctor/capture_verifier"

    class << self
      def call
        new.checks
      end

      def report(checks = call)
        (["LLM Cost Tracker doctor"] + checks.map do |check|
          "[#{check.status}] #{check.name}: #{check.message}"
        end).join("\n")
      end

      def healthy?(checks = call)
        checks.none? { |check| check.status == :error }
      end
    end

    def checks
      [
        configuration_check,
        capture_check,
        *LlmCostTracker::Integrations.checks,
        active_record_check,
        table_check,
        column_check,
        SchemaCheck.new(name: "call line items", schema: Ledger::Schema::CallLineItems,
                        table: "llm_cost_tracker_call_line_items").call,
        SchemaCheck.new(name: "call tags", schema: Ledger::Schema::CallTags,
                        table: "llm_cost_tracker_call_tags").call,
        *reconciliation_schema_checks,
        CostDriftCheck.new.call,
        PricingSnapshotDriftCheck.new.call,
        *reconciliation_invoice_check,
        LegacyBillingStatusCheck.new.call,
        LegacyAuditCheck.new.call,
        call_rollups_check,
        IngestionCheck.new.call,
        PriceCheck.new.call,
        calls_check
      ].compact
    end

    private

    def reconciliation_schema_checks
      return [] unless LlmCostTracker.reconciliation_enabled?

      Reconciliation::SCHEMA_TABLES.map do |schema, table|
        SchemaCheck.new(name: table.delete_prefix("llm_cost_tracker_").tr("_", " "),
                        schema: schema, table: table,
                        optional: false, install_command: "llm_cost_tracker:reconciliation").call
      end.compact
    end

    def reconciliation_invoice_check
      return [] unless LlmCostTracker.reconciliation_enabled?

      Array(InvoiceReconciliationCheck.new.call)
    end

    def configuration_check
      config = LlmCostTracker.configuration
      Check.new(:ok, "configuration", "active_record ledger enabled=#{config.enabled}")
    end

    def capture_check
      config = LlmCostTracker.configuration
      unless config.enabled
        return Check.new(:warn, "capture", "tracking is disabled; set config.enabled = true to record calls")
      end

      if config.instrumented_integrations.any?
        return Check.new(
          :ok,
          "capture",
          "SDK integrations enabled: #{config.instrumented_integrations.to_a.join(', ')}"
        )
      end

      Check.new(
        :ok,
        "capture",
        "no SDK integrations enabled; Faraday middleware and manual capture remain available"
      )
    end

    def active_record_check
      return Check.new(:ok, "active_record", "available") if active_record_available?

      Check.new(:error, "active_record", "unavailable")
    end

    def table_check
      return unless active_record_available?
      return Check.new(:ok, "llm_cost_tracker_calls", "table exists") if llm_cost_tracker_calls_table?

      Check.new(
        :error,
        "llm_cost_tracker_calls",
        "missing; run bin/rails generate llm_cost_tracker:install && bin/rails db:migrate"
      )
    end

    def column_check
      return unless llm_cost_tracker_calls_table?

      errors = LlmCostTracker::Ledger::Schema::Calls.current_schema_errors
      return Check.new(:ok, "llm_cost_tracker_calls columns", "current") if errors.empty?

      Check.new(
        :error,
        "llm_cost_tracker_calls columns",
        "schema mismatch: #{errors.join('; ')}; see docs/upgrading.md"
      )
    end

    def call_rollups_check
      return unless llm_cost_tracker_calls_table?
      return live_rollups_check unless LlmCostTracker.configuration.cache_rollups

      errors = LlmCostTracker::Ledger::Schema::CallRollups.current_schema_errors
      return rollups_drift_check if errors.empty?

      Check.new(
        :error,
        "call rollups",
        "schema mismatch: #{errors.join('; ')}; see docs/upgrading.md"
      )
    end

    ROLLUPS_DRIFT_TOLERANCE_PERCENT = 1.0
    private_constant :ROLLUPS_DRIFT_TOLERANCE_PERCENT

    def rollups_drift_check
      drift_window = Time.now.utc.beginning_of_day
      calls_total = LlmCostTracker::Call
                    .where(tracked_at: drift_window..)
                    .where.not(total_cost: nil)
                    .sum(:total_cost)
      rollup_total = LlmCostTracker::CallRollup
                     .where(period: "day", period_start: drift_window.to_date)
                     .sum(:total_cost)
      return Check.new(:ok, "call rollups", "llm_cost_tracker_call_rollups exists") if calls_total.zero?

      drift_percent = ((calls_total - rollup_total).abs * 100.0 / calls_total)
      if drift_percent > ROLLUPS_DRIFT_TOLERANCE_PERCENT
        return Check.new(
          :warn, "call rollups",
          "rollups drift detected: today's calls SUM=#{calls_total} vs rollups SUM=#{rollup_total} " \
          "(#{drift_percent.round(2)}% > #{ROLLUPS_DRIFT_TOLERANCE_PERCENT}% threshold). " \
          "Cached budget reads may understate spend until a rebuild."
        )
      end

      Check.new(:ok, "call rollups", "llm_cost_tracker_call_rollups exists")
    rescue StandardError => e
      Check.new(:warn, "call rollups", "rollups drift check failed: #{e.class}: #{e.message}")
    end

    def live_rollups_check
      if Probe.table_exists?("llm_cost_tracker_call_rollups")
        Check.new(
          :warn,
          "call rollups",
          "cache_rollups=false but llm_cost_tracker_call_rollups exists. " \
          "Set config.cache_rollups = true to keep budget reads on the rollups fast path or drop the table."
        )
      else
        Check.new(
          :ok,
          "call rollups",
          "cache_rollups=false; budget reads aggregate from llm_cost_tracker_calls directly"
        )
      end
    end

    def calls_check
      return unless llm_cost_tracker_calls_table?

      snapshot = LlmCostTracker::Call
                 .select("COUNT(*) AS tracked_call_count, MAX(tracked_at) AS latest_tracked_at")
                 .take
      count = snapshot.tracked_call_count.to_i
      return Check.new(:warn, "tracked calls", "none recorded yet") if count.zero?

      latest_at = snapshot.latest_tracked_at
      latest_at = latest_at.to_time if latest_at.respond_to?(:to_time)
      latest = latest_at&.utc&.iso8601
      Check.new(:ok, "tracked calls", "#{count} recorded; latest #{latest}")
    end

    def active_record_available?
      LlmCostTracker::Call.connection
      true
    rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError
      false
    end

    def llm_cost_tracker_calls_table? = active_record_available? && Probe.table_exists?("llm_cost_tracker_calls")
  end
end
