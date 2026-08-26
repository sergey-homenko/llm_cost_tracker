# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    module SetupState
      SetupRequired = Data.define(:message, :details)

      class << self
        def current
          return if @healthy

          state = compute
          @healthy = state.nil?
          state
        end

        def reset!
          @healthy = false
        end

        private

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
