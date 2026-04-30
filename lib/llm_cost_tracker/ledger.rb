# frozen_string_literal: true

require "securerandom"

require_relative "ledger/database_adapter"
require_relative "ledger/schema_capabilities"
require_relative "ledger/period_grouping"
require_relative "ledger/tags/accessors"
require_relative "ledger/tags/query"
require_relative "ledger/tags/sql"
require_relative "ledger/call_metrics"
require_relative "ledger/call"
require_relative "ledger/periods"
require_relative "ledger/period_total"
require_relative "ledger/rollups/batch"
require_relative "ledger/rollups/upsert_sql"
require_relative "ledger/rollups"
require_relative "ledger/ingestion/event"
require_relative "ledger/ingestion/lease"
require_relative "ledger/ingestion/lease_claim"
require_relative "ledger/ingestion/inbox"
require_relative "ledger/store"
require_relative "ledger/ingestion/batch"
require_relative "ledger/ingestion/worker"
require_relative "ledger/period_totals"

module LlmCostTracker
  class Ledger
    VerificationResult = Data.define(:status, :name, :message)

    VERIFY_TAG = "llm_cost_tracker_verify"

    class << self
      def save(event)
        if Ledger::Ingestion::Inbox.enabled?
          Ledger::Ingestion::Inbox.save(event)
        else
          Ledger::Store.save(event)
        end
        event
      end

      def verify
        unless LlmCostTracker::Ledger::Call.table_exists?
          return [
            VerificationResult.new(
              :error,
              "active_record",
              "llm_api_calls table is missing; run install generator and migrate"
            )
          ]
        end

        [capture_check]
      rescue StandardError => e
        [VerificationResult.new(:error, "active_record", "#{e.class}: #{e.message}")]
      end

      private

      def capture_check
        return inbox_capture_check if Ledger::Ingestion::Inbox.enabled?

        provider, model = sample_priced_identity
        response_id = "lct_verify_#{SecureRandom.hex(8)}"
        notifications = []
        persisted = false
        subscription = subscribe_to_verification(response_id, notifications)

        LlmCostTracker::Ledger::Call.transaction do
          LlmCostTracker.track(
            provider: provider,
            model: model,
            input_tokens: 1,
            output_tokens: 1,
            provider_response_id: response_id,
            feature: VERIFY_TAG
          )
          persisted = LlmCostTracker::Ledger::Call.where(provider_response_id: response_id).exists?
          raise ActiveRecord::Rollback
        end

        return capture_success if persisted && notifications.any?

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

      def inbox_capture_check
        provider, model = sample_priced_identity
        response_id = "lct_verify_#{SecureRandom.hex(8)}"
        notifications = []
        subscription = subscribe_to_verification(response_id, notifications)

        event = LlmCostTracker.track(
          provider: provider,
          model: model,
          input_tokens: 1,
          output_tokens: 1,
          provider_response_id: response_id,
          feature: VERIFY_TAG
        )
        LlmCostTracker.flush!
        persisted = LlmCostTracker::Ledger::Call.where(provider_response_id: response_id).exists?

        if persisted && notifications.any?
          return capture_success("manual event emitted and persisted through durable inbox")
        end

        VerificationResult.new(:error, "active_record capture", capture_failure_message(persisted, notifications))
      rescue LlmCostTracker::BudgetExceededError => e
        VerificationResult.new(:error, "active_record capture", "blocked by budget guardrail: #{e.message}")
      rescue LlmCostTracker::Error => e
        VerificationResult.new(:error, "active_record capture", e.message)
      rescue StandardError => e
        VerificationResult.new(:error, "active_record capture", "#{e.class}: #{e.message}")
      ensure
        cleanup_verification_call(response_id) if response_id
        LlmCostTracker::Ledger::Ingestion::Event.where(event_id: event.event_id).delete_all if event
        ActiveSupport::Notifications.unsubscribe(subscription) if subscription
      end

      def subscribe_to_verification(response_id, notifications)
        ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
          notifications << payload if payload[:provider_response_id] == response_id
        end
      end

      def capture_success(message = "manual event emitted and persisted inside rollback")
        VerificationResult.new(
          :ok,
          "active_record capture",
          message
        )
      end

      def capture_failure_message(persisted, notifications)
        missing = []
        missing << "notification" if notifications.empty?
        missing << "persisted row" unless persisted
        "missing #{missing.join(' and ')} for synthetic manual event"
      end

      def cleanup_verification_call(response_id)
        relation = LlmCostTracker::Ledger::Call.where(provider_response_id: response_id)
        rows = relation.pluck(:id, :tracked_at, :total_cost)
        return if rows.empty?

        relation.delete_all
        Ledger::Rollups.decrement!(rows)
      end

      def sample_priced_identity
        key = LlmCostTracker::Pricing::Registry.builtin_prices.find do |model_id, prices|
          model_id.include?("/") && prices[:input] && prices[:output]
        end&.first
        provider, model = key.to_s.split("/", 2)
        [provider || "openai", model || "gpt-4o-mini"]
      end
    end
  end
end
