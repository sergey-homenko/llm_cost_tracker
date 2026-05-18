# frozen_string_literal: true

require "llm_cost_tracker/ledger/schema/calls"
require "llm_cost_tracker/ledger/schema/call_line_items"
require "llm_cost_tracker/ledger/schema/call_tags"
require "llm_cost_tracker/ledger/schema/call_rollups"

module LlmCostTracker
  module Dashboard
    module SetupState
      SetupRequired = Data.define(:message, :details)
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
          fingerprint = schema_fingerprint

          MUTEX.synchronize do
            if !defined?(@cache_fingerprint) || @cache_fingerprint != fingerprint
              LlmCostTracker::Call.reset_column_information
              @cached = compute
              @cache_fingerprint = fingerprint
            end
          end
          @cached
        end

        def reset!
          MUTEX.synchronize do
            remove_instance_variable(:@cached) if defined?(@cached)
            remove_instance_variable(:@cache_fingerprint) if defined?(@cache_fingerprint)
          end
        end

        private

        SCHEMA_MIGRATIONS_TABLE = "schema_migrations"
        private_constant :SCHEMA_MIGRATIONS_TABLE

        def schema_fingerprint
          connection = ActiveRecord::Base.connection
          quoted = connection.quote_table_name(SCHEMA_MIGRATIONS_TABLE)
          connection.query_value("SELECT MAX(version) FROM #{quoted}")
        rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished
          nil
        end

        def compute
          LlmCostTracker::Logging.debug("Dashboard::SetupState recomputing")
          return calls_table_missing unless LlmCostTracker::Call.table_exists?

          core_drift = drift_in(schema_checks_for_current_config)
          return core_drift if core_drift
          return nil unless LlmCostTracker.reconciliation_enabled?

          reconciliation_drift
        end

        def schema_checks_for_current_config
          return CORE_SCHEMA_CHECKS unless LlmCostTracker.configuration.cache_rollups

          CORE_SCHEMA_CHECKS + [OPTIONAL_CALL_ROLLUPS_CHECK]
        end

        def drift_in(checks)
          checks.each do |schema, message|
            errors = schema.current_schema_errors
            next if errors.empty?

            return SetupRequired.new(message: message, details: errors + [DOCS_HINT])
          end
          nil
        end

        def reconciliation_drift
          connection = ActiveRecord::Base.connection
          LlmCostTracker::Reconciliation::SCHEMA_TABLES.each do |schema, table|
            unless connection.data_source_exists?(table)
              return SetupRequired.new(
                message: "The #{table} table is required when reconciliation is enabled.",
                details: ["run bin/rails generate llm_cost_tracker:reconciliation && bin/rails db:migrate", DOCS_HINT]
              )
            end

            errors = schema.current_schema_errors
            next if errors.empty?

            message = "The #{table} table does not match the current LLM Cost Tracker schema."
            return SetupRequired.new(message: message, details: errors + [DOCS_HINT])
          end
          nil
        end

        def calls_table_missing
          SetupRequired.new(
            message: "The llm_cost_tracker_calls table is not available yet.",
            details: nil
          )
        end
      end
    end
  end
end
