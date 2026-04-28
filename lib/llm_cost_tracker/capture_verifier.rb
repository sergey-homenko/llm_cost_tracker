# frozen_string_literal: true

require "securerandom"

module LlmCostTracker
  class CaptureVerifier
    Check = Data.define(:status, :name, :message)
    VERIFY_TAG = "llm_cost_tracker_verify"

    class << self
      def call = new.checks

      def report(checks = call)
        (["LLM Cost Tracker capture verification"] + checks.map { |check| format_check(check) }).join("\n")
      end

      def healthy?(checks = call)
        checks.none? { |check| check.status == :error }
      end

      private

      def format_check(check)
        "[#{check.status}] #{check.name}: #{check.message}"
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
      case LlmCostTracker.configuration.storage_backend
      when :active_record then active_record_checks
      when :custom        then custom_storage_checks
      when :log           then [Check.new(:ok, "storage", "log backend configured; capture writes to logs only")]
      else
        [Check.new(:error, "storage", "unknown backend #{LlmCostTracker.configuration.storage_backend.inspect}")]
      end
    end

    def custom_storage_checks
      callable = LlmCostTracker.configuration.custom_storage.respond_to?(:call)
      if callable
        [Check.new(:ok, "storage", "custom storage callable configured; external sink was not invoked")]
      else
        [Check.new(:error, "storage", "custom storage backend requires config.custom_storage")]
      end
    end

    def active_record_checks
      require_relative "llm_api_call" unless defined?(LlmCostTracker::LlmApiCall)

      unless LlmCostTracker::LlmApiCall.table_exists?
        return [
          Check.new(:error, "active_record", "llm_api_calls table is missing; run install generator and migrate")
        ]
      end

      [active_record_capture_check]
    rescue LoadError => e
      [Check.new(:error, "active_record", "unavailable: #{e.message}")]
    rescue StandardError => e
      [Check.new(:error, "active_record", "#{e.class}: #{e.message}")]
    end

    def active_record_capture_check
      provider, model = sample_priced_identity
      response_id = "lct_verify_#{SecureRandom.hex(8)}"
      notifications = []
      persisted = false
      subscription = subscribe_to_verification(response_id, notifications)

      LlmCostTracker::LlmApiCall.transaction do
        LlmCostTracker.track(
          provider: provider,
          model: model,
          input_tokens: 1,
          output_tokens: 1,
          provider_response_id: response_id,
          feature: VERIFY_TAG
        )
        persisted = LlmCostTracker::LlmApiCall.where(provider_response_id: response_id).exists?
        raise ActiveRecord::Rollback
      end

      if persisted && notifications.any?
        return Check.new(:ok, "active_record capture", "manual event emitted and persisted inside rollback")
      end

      Check.new(:error, "active_record capture", capture_failure_message(persisted, notifications))
    rescue LlmCostTracker::BudgetExceededError => e
      Check.new(:error, "active_record capture", "blocked by budget guardrail: #{e.message}")
    rescue LlmCostTracker::Error => e
      Check.new(:error, "active_record capture", e.message)
    rescue StandardError => e
      Check.new(:error, "active_record capture", "#{e.class}: #{e.message}")
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    end

    def subscribe_to_verification(response_id, notifications)
      ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
        notifications << payload if payload[:provider_response_id] == response_id
      end
    end

    def capture_failure_message(persisted, notifications)
      missing = []
      missing << "notification" if notifications.empty?
      missing << "persisted row" unless persisted
      "missing #{missing.join(' and ')} for synthetic manual event"
    end

    def sample_priced_identity
      key = LlmCostTracker::PriceRegistry.builtin_prices.find do |model_id, prices|
        model_id.include?("/") && prices[:input] && prices[:output]
      end&.first
      provider, model = key.to_s.split("/", 2)
      [provider || "openai", model || "gpt-4o-mini"]
    end
  end
end
