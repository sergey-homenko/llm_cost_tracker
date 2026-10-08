# frozen_string_literal: true

require "active_support/notifications"
require "securerandom"

require_relative "errors"
require_relative "check"
require_relative "ledger"

module LlmCostTracker
  module Ingestion
    autoload :LeaseClaim, "llm_cost_tracker/ingestion/lease_claim"
    autoload :Pool, "llm_cost_tracker/ingestion/pool"
    autoload :Inbox, "llm_cost_tracker/ingestion/inbox"
    autoload :Batch, "llm_cost_tracker/ingestion/batch"
    autoload :Worker, "llm_cost_tracker/ingestion/worker"

    VERIFY_TAG = "llm_cost_tracker_verify"
    CAPTURE_CHECK = "active_record capture"
    MISSING_CALLS_TABLE = "llm_cost_tracker_calls table is missing; run install generator and migrate"

    class << self
      def table_name_prefix
        "llm_cost_tracker_ingestion_"
      end

      def ensure_current_schema!
        raise Error, MISSING_CALLS_TABLE unless LlmCostTracker::Call.table_exists?

        guards_for_current_config.each do |schema_module, table_name|
          next if schema_module == Ledger::Schema::CallRollups && !Ledger::Rollups.cache_active?

          errors = schema_module.current_schema_errors
          next if errors.empty?

          raise Error,
                "#{table_name} table is not on the current schema: #{errors.join('; ')}; see docs/upgrading.md"
        end
      end

      def async?
        LlmCostTracker.configuration.ingestion.mode == :async
      end

      def guards_for_current_config
        guards = Ledger::Schema::CORE_SCHEMAS.dup
        guards << Ledger::Schema::CACHE_ROLLUPS_SCHEMA if LlmCostTracker.configuration.budgets.totals_source == :cache
        guards += Ledger::Schema::ASYNC_SCHEMAS if async?
        guards
      end

      def verify
        unless LlmCostTracker::Call.table_exists?
          return [LlmCostTracker::Check.new(:error, "active_record", MISSING_CALLS_TABLE)]
        end

        [capture_check]
      rescue StandardError => e
        [LlmCostTracker::Check.new(:error, "active_record", "#{e.class}: #{e.message}")]
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
          tokens: { input_tokens: 1, output_tokens: 1 },
          provider_response_id: response_id,
          tags: { feature: VERIFY_TAG }
        )
        LlmCostTracker::Ingestion::Worker.flush! if async?
        capture_result(LlmCostTracker::Call.where(provider_response_id: response_id).exists?, notifications)
      rescue StandardError => e
        LlmCostTracker::Check.new(:error, CAPTURE_CHECK, capture_error_message(e))
      ensure
        cleanup_verification_call(response_id) if response_id
        cleanup_verification_inbox(event: event, response_id: response_id)
        ActiveSupport::Notifications.unsubscribe(subscription) if subscription
      end

      def subscribe_to_verification(response_id, notifications)
        ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
          notifications << payload if payload[:provider_response_id] == response_id
        end
      end

      def capture_result(persisted, notifications)
        if persisted && notifications.any?
          path = async? ? "async inbox" : "inline writer"
          return LlmCostTracker::Check.new(:ok, CAPTURE_CHECK, "manual event emitted and persisted through #{path}")
        end

        missing = []
        missing << "notification" if notifications.empty?
        missing << "persisted row" unless persisted
        LlmCostTracker::Check.new(:error, CAPTURE_CHECK, "missing #{missing.join(' and ')} for synthetic manual event")
      end

      def capture_error_message(error)
        case error
        when LlmCostTracker::BudgetExceededError then "blocked by budget guardrail: #{error.message}"
        when LlmCostTracker::Error then error.message
        else "#{error.class}: #{error.message}"
        end
      end

      def cleanup_verification_call(response_id)
        relation = LlmCostTracker::Call.where(provider_response_id: response_id)
        records = relation.select(:id, *LlmCostTracker::Ledger::Rollups::SOURCE_COLUMNS).to_a
        return if records.empty?

        relation.delete_all
        LlmCostTracker::Ledger::Rollups.decrement!(records)
      end

      def cleanup_verification_inbox(event:, response_id:)
        return unless async? && LlmCostTracker::Ingestion::InboxEntry.table_exists?

        if event
          LlmCostTracker::Ingestion::InboxEntry.where(event_id: event.event_id).delete_all
        elsif response_id
          escaped = ActiveRecord::Base.sanitize_sql_like(response_id)
          LlmCostTracker::Ingestion::InboxEntry
            .where("payload LIKE ?", "%\"provider_response_id\":\"#{escaped}\"%")
            .delete_all
        end
      end

      def sample_priced_identity
        key = LlmCostTracker::Pricing::Registry.builtin_prices.find do |model_id, prices|
          model_id.include?("/") && prices["input"] && prices["output"]
        end&.first
        provider, model = key.to_s.split("/", 2)
        [provider || "openai", model || "gpt-4o-mini"]
      end
    end
  end
end
