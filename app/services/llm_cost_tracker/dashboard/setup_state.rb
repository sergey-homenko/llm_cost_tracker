# frozen_string_literal: true

require "llm_cost_tracker/ledger"

module LlmCostTracker
  module Dashboard
    module SetupState
      SetupRequired = Data.define(:message, :details)
      MUTEX = Mutex.new

      private_constant :MUTEX

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

          drift_in(LlmCostTracker::Ingestion.guards_for_current_config)
        end

        def drift_in(checks)
          checks.each do |schema, table|
            errors = schema.current_schema_errors
            next if errors.empty?

            message = "The #{table} table does not match the current LLM Cost Tracker schema."
            return SetupRequired.new(message: message, details: errors)
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
