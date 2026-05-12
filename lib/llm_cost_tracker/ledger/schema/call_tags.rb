# frozen_string_literal: true

module LlmCostTracker
  module Ledger
    module Schema
      module CallTags
        REQUIRED_COLUMNS = %w[llm_cost_tracker_call_id key value].freeze

        REQUIRED_INDEX_COLUMNS = [
          %w[key value],
          %w[llm_cost_tracker_call_id]
        ].freeze

        class << self
          def current_schema_errors
            connection = LlmCostTracker::Call.connection
            Ledger::Schema::Adapter.ensure_supported!(connection)
            table_name = LlmCostTracker::CallTag.table_name
            return ["#{table_name} table is missing"] unless connection.data_source_exists?(table_name)

            columns = LlmCostTracker::CallTag.columns_hash
            errors = []
            missing = REQUIRED_COLUMNS - columns.keys
            errors << "missing columns: #{missing.join(', ')}" if missing.any?
            errors.concat(missing_index_errors(connection, table_name))
            errors
          end

          def missing_index_errors(connection, table_name)
            existing = connection.indexes(table_name).map { |index| Array(index.columns).map(&:to_s) }
            REQUIRED_INDEX_COLUMNS.filter_map do |required|
              next if existing.any? { |columns| (required - columns).empty? }

              "missing index on (#{required.join(', ')})"
            end
          end
        end
      end
    end
  end
end
