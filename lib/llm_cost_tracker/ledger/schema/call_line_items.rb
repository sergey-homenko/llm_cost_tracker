# frozen_string_literal: true

require_relative "adapter"

module LlmCostTracker
  module Ledger
    module Schema
      module CallLineItems
        REQUIRED_COLUMNS = %w[
          llm_cost_tracker_call_id
          position
          kind
          direction
          modality
          cache_state
          quantity
          unit
          rate_amount
          rate_quantity
          cost
          currency
          cost_status
          pricing_basis
          price_key
          price_source
          price_source_version
          provider_field
          provider_item_id
          details
          created_at
        ].freeze

        REQUIRED_INDEX_COLUMNS = [
          %w[llm_cost_tracker_call_id position]
        ].freeze

        class << self
          def current_schema_errors
            connection = LlmCostTracker::Call.connection
            Adapter.ensure_supported!(connection)
            table_name = LlmCostTracker::CallLineItem.table_name
            return ["#{table_name} table is missing"] unless connection.data_source_exists?(table_name)

            columns = LlmCostTracker::CallLineItem.columns_hash
            errors = []
            missing = REQUIRED_COLUMNS - columns.keys
            errors << "missing columns: #{missing.join(', ')}" if missing.any?
            errors.concat(Adapter.json_column_errors(columns["details"], connection, "details"))
            errors.concat(missing_index_errors(connection, table_name))
            errors << missing_fk_error(connection, table_name) if missing_fk?(connection, table_name)
            errors.compact
          end

          def missing_index_errors(connection, table_name)
            existing = connection.indexes(table_name).map { |index| Array(index.columns).map(&:to_s) }
            REQUIRED_INDEX_COLUMNS.filter_map do |required|
              next if existing.any? { |columns| columns == required }

              "missing index on (#{required.join(', ')})"
            end
          end

          def missing_fk?(connection, table_name)
            connection.foreign_keys(table_name).none? do |fk|
              fk.column.to_s == "llm_cost_tracker_call_id" &&
                fk.to_table.to_s == "llm_cost_tracker_calls"
            end
          rescue NotImplementedError, NoMethodError
            false
          end

          def missing_fk_error(_connection, _table_name)
            "missing foreign key on llm_cost_tracker_call_id referencing llm_cost_tracker_calls"
          end
        end
      end
    end
  end
end
