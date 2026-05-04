# frozen_string_literal: true

require "securerandom"

require_relative "doctor/check"
require_relative "errors"
require_relative "ledger"
require_relative "ingestion/lease_claim"
require_relative "ingestion/inbox"
require_relative "ingestion/batch"
require_relative "ingestion/worker"

module LlmCostTracker
  module Ingestion
    VERIFY_TAG = "llm_cost_tracker_verify"

    class << self
      def table_name_prefix
        "llm_cost_tracker_ingestion_"
      end

      def ensure_current_schema!
        unless LlmCostTracker::Call.table_exists?
          raise Error, "llm_cost_tracker_calls table is missing; run install generator and migrate"
        end

        schema_errors = Ledger::Schema::Calls.current_schema_errors
        message = "llm_cost_tracker_calls table is not on the current schema: #{schema_errors.join('; ')}"
        raise Error, message if schema_errors.any?

        call_rollup_errors = Ledger::Schema::CallRollups.current_schema_errors
        return if call_rollup_errors.empty?

        message = "llm_cost_tracker_call_rollups table is not on the current schema: " \
                  "#{call_rollup_errors.join('; ')}; " \
                  "run bin/rails generate llm_cost_tracker:add_call_rollups && bin/rails db:migrate"
        raise Error, message
      end

      def verify
        unless LlmCostTracker::Call.table_exists?
          return [
            LlmCostTracker::Doctor::Check.new(
              :error,
              "active_record",
              "llm_cost_tracker_calls table is missing; run install generator and migrate"
            )
          ]
        end

        [capture_check]
      rescue StandardError => e
        [LlmCostTracker::Doctor::Check.new(:error, "active_record", "#{e.class}: #{e.message}")]
      end

      private

      def capture_check
        provider, model = sample_priced_identity
        response_id = "lct_verify_#{SecureRandom.hex(8)}"
        notifications = []
        subscription = subscribe_to_verification(response_id, notifications)

        event = LlmCostTracker.track(
          provider: provider,
          model: model,
          tokens: { input: 1, output: 1 },
          provider_response_id: response_id,
          tags: { feature: VERIFY_TAG }
        )
        LlmCostTracker.flush!
        persisted = LlmCostTracker::Call.where(provider_response_id: response_id).exists?

        return capture_success if persisted && notifications.any?

        LlmCostTracker::Doctor::Check.new(
          :error,
          "active_record capture",
          capture_failure_message(persisted, notifications)
        )
      rescue LlmCostTracker::BudgetExceededError => e
        LlmCostTracker::Doctor::Check.new(:error, "active_record capture", "blocked by budget guardrail: #{e.message}")
      rescue LlmCostTracker::Error => e
        LlmCostTracker::Doctor::Check.new(:error, "active_record capture", e.message)
      rescue StandardError => e
        LlmCostTracker::Doctor::Check.new(:error, "active_record capture", "#{e.class}: #{e.message}")
      ensure
        cleanup_verification_call(response_id) if response_id
        LlmCostTracker::Ingestion::InboxEntry.where(event_id: event.event_id).delete_all if event
        ActiveSupport::Notifications.unsubscribe(subscription) if subscription
      end

      def subscribe_to_verification(response_id, notifications)
        ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
          notifications << payload if payload[:provider_response_id] == response_id
        end
      end

      def capture_success
        LlmCostTracker::Doctor::Check.new(
          :ok,
          "active_record capture",
          "manual event emitted and persisted through durable inbox"
        )
      end

      def capture_failure_message(persisted, notifications)
        missing = []
        missing << "notification" if notifications.empty?
        missing << "persisted row" unless persisted
        "missing #{missing.join(' and ')} for synthetic manual event"
      end

      def cleanup_verification_call(response_id)
        relation = LlmCostTracker::Call.where(provider_response_id: response_id)
        rows = relation.pluck(:id, :tracked_at, :total_cost)
        return if rows.empty?

        relation.delete_all
        LlmCostTracker::Ledger::Rollups.decrement!(rows)
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
