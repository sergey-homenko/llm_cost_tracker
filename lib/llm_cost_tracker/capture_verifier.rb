# frozen_string_literal: true

require_relative "ledger"

module LlmCostTracker
  class CaptureVerifier
    Check = Data.define(:status, :name, :message)

    class << self
      def call
        new.checks
      end

      def report(checks = call)
        (["LLM Cost Tracker capture verification"] + checks.map do |check|
          "[#{check.status}] #{check.name}: #{check.message}"
        end).join("\n")
      end

      def healthy?(checks = call)
        checks.none? { |check| check.status == :error }
      end
    end

    def checks
      [
        enabled_check,
        *integration_checks,
        *storage_checks
      ].compact
    end

    private

    def enabled_check
      return Check.new(:ok, "tracking", "enabled") if LlmCostTracker.configuration.enabled

      Check.new(:error, "tracking", "disabled; set config.enabled = true before verifying capture")
    end

    def integration_checks
      enabled = LlmCostTracker.configuration.instrumented_integrations
      if enabled.empty?
        return [
          Check.new(:ok, "sdk integrations", "none enabled; Faraday middleware and manual capture remain available")
        ]
      end

      LlmCostTracker::Integrations.checks.map do |check|
        Check.new(check.status, "sdk integration #{check.name}", check.message)
      end
    end

    def storage_checks
      LlmCostTracker::Ledger.verify.map do |check|
        Check.new(check.status, check.name, check.message)
      end
    rescue LlmCostTracker::Error => e
      [Check.new(:error, "storage", e.message)]
    end
  end
end
