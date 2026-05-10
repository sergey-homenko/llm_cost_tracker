# frozen_string_literal: true

require_relative "ledger/schema/calls"
require_relative "ledger/schema/call_line_items"
require_relative "ledger/schema/call_tags"
require_relative "ledger/schema/call_rollups"

module LlmCostTracker
  module DashboardSetupState
    Result = Data.define(:setup_required, :message, :details) do
      alias_method :setup_required?, :setup_required
    end
    OK = Result.new(setup_required: false, message: nil, details: nil)
    DOCS_HINT = "See docs/upgrading.md for the migration path."
    MUTEX = Mutex.new

    CORE_SCHEMA_CHECKS = [
      [
        LlmCostTracker::Ledger::Schema::Calls,
        "The llm_cost_tracker_calls table does not match the current LLM Cost Tracker schema."
      ],
      [
        LlmCostTracker::Ledger::Schema::CallLineItems,
        "The llm_cost_tracker_call_line_items table does not match the current LLM Cost Tracker schema."
      ],
      [
        LlmCostTracker::Ledger::Schema::CallTags,
        "The llm_cost_tracker_call_tags table does not match the current LLM Cost Tracker schema."
      ]
    ].freeze

    OPTIONAL_CALL_ROLLUPS_CHECK = [
      LlmCostTracker::Ledger::Schema::CallRollups,
      "The llm_cost_tracker_call_rollups table does not match the current LLM Cost Tracker schema."
    ].freeze

    private_constant :MUTEX, :CORE_SCHEMA_CHECKS, :OPTIONAL_CALL_ROLLUPS_CHECK, :DOCS_HINT

    class << self
      def current
        cached = @cached
        return cached if cached

        MUTEX.synchronize { @cached ||= compute }
      end

      def reset!
        MUTEX.synchronize { @cached = nil }
      end

      private

      def compute
        return calls_table_missing unless LlmCostTracker::Call.table_exists?

        core_drift = drift_in(schema_checks_for_current_config)
        return core_drift if core_drift
        return OK unless LlmCostTracker.reconciliation_enabled?

        reconciliation_drift || OK
      end

      def schema_checks_for_current_config
        return CORE_SCHEMA_CHECKS unless LlmCostTracker.configuration.cache_rollups

        CORE_SCHEMA_CHECKS + [OPTIONAL_CALL_ROLLUPS_CHECK]
      end

      def drift_in(checks)
        checks.each do |schema, message|
          errors = schema.current_schema_errors
          next if errors.empty?

          return Result.new(setup_required: true, message: message, details: errors + [DOCS_HINT])
        end
        nil
      end

      def reconciliation_drift
        LlmCostTracker.const_get(:Reconciliation) # autoload reconciliation + its ledger schemas
        connection = ActiveRecord::Base.connection
        LlmCostTracker::Reconciliation::SCHEMA_TABLES.each do |schema, table|
          next unless connection.data_source_exists?(table)

          errors = schema.current_schema_errors
          next if errors.empty?

          message = "The #{table} table does not match the current LLM Cost Tracker schema."
          return Result.new(setup_required: true, message: message, details: errors + [DOCS_HINT])
        end
        nil
      end

      def calls_table_missing
        Result.new(
          setup_required: true,
          message: "The llm_cost_tracker_calls table is not available yet.",
          details: nil
        )
      end
    end
  end
end
