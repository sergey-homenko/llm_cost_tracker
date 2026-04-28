# frozen_string_literal: true

require "securerandom"

require_relative "registry"
require_relative "active_record_store"

module LlmCostTracker
  module Storage
    class ActiveRecordBackend
      VERIFY_TAG = "llm_cost_tracker_verify"

      class << self
        def save(event)
          require_relative "../llm_api_call" unless defined?(LlmCostTracker::LlmApiCall)

          ActiveRecordStore.save(event)
          event
        rescue LoadError => e
          raise Error, "ActiveRecord storage requires the active_record gem: #{e.message}"
        end

        def verify
          require_relative "../llm_api_call" unless defined?(LlmCostTracker::LlmApiCall)

          unless LlmCostTracker::LlmApiCall.table_exists?
            return [
              VerificationResult.new(
                :error,
                "active_record",
                "llm_api_calls table is missing; run install generator and migrate"
              )
            ]
          end

          [active_record_capture_check]
        rescue LoadError => e
          [VerificationResult.new(:error, "active_record", "unavailable: #{e.message}")]
        rescue StandardError => e
          [VerificationResult.new(:error, "active_record", "#{e.class}: #{e.message}")]
        end

        def prune(cutoff:, batch_size:)
          require_relative "../llm_api_call" unless defined?(LlmCostTracker::LlmApiCall)

          ActiveRecordStore.prune(cutoff: cutoff, batch_size: batch_size)
        end

        private

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

          return active_record_capture_success if persisted && notifications.any?

          VerificationResult.new(:error, "active_record capture", capture_failure_message(persisted, notifications))
        rescue LlmCostTracker::BudgetExceededError => e
          VerificationResult.new(:error, "active_record capture", "blocked by budget guardrail: #{e.message}")
        rescue LlmCostTracker::Error => e
          VerificationResult.new(:error, "active_record capture", e.message)
        rescue StandardError => e
          VerificationResult.new(:error, "active_record capture", "#{e.class}: #{e.message}")
        ensure
          ActiveSupport::Notifications.unsubscribe(subscription) if subscription
        end

        def subscribe_to_verification(response_id, notifications)
          ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
            notifications << payload if payload[:provider_response_id] == response_id
          end
        end

        def active_record_capture_success
          VerificationResult.new(
            :ok,
            "active_record capture",
            "manual event emitted and persisted inside rollback"
          )
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
  end
end
