# frozen_string_literal: true

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
        ].freeze

        class << self
          def current_schema_errors
            connection = LlmCostTracker::Call.connection
            Ledger::Schema::Adapter.ensure_supported!(connection)
            table_name = LlmCostTracker::CallLineItem.table_name
            return ["#{table_name} table is missing"] unless connection.data_source_exists?(table_name)

            columns = LlmCostTracker::CallLineItem.columns_hash
            errors = []
            missing = REQUIRED_COLUMNS - columns.keys
            errors << "missing columns: #{missing.join(', ')}" if missing.any?
            errors.concat(json_column_errors(columns, connection))
            errors
          end

          private

          def json_column_errors(columns, connection)
            column = columns["details"]
            return [] unless column

            postgresql = Ledger::Schema::Adapter.postgresql?(connection)
            expected_type = postgresql ? "jsonb" : "json"
            valid_type =
              if postgresql
                column.type == :jsonb || column.sql_type.to_s.downcase == "jsonb"
              else
                column.type == :json
              end

            valid_type ? [] : ["details column must use #{expected_type}"]
          end
        end
      end
    end
  end
end
