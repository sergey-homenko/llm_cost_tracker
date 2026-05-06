# frozen_string_literal: true

module LlmCostTracker
  module Ledger
    module Schema
      module CallTags
        REQUIRED_COLUMNS = %w[llm_cost_tracker_call_id key value].freeze

        class << self
          def current_schema_errors
            connection = LlmCostTracker::Call.connection
            Ledger::Schema::Adapter.ensure_supported!(connection)
            table_name = LlmCostTracker::CallTag.table_name
            return ["#{table_name} table is missing"] unless connection.data_source_exists?(table_name)

            columns = LlmCostTracker::CallTag.columns_hash
            missing = REQUIRED_COLUMNS - columns.keys
            return [] if missing.empty?

            ["missing columns: #{missing.join(', ')}"]
          end
        end
      end
    end
  end
end
