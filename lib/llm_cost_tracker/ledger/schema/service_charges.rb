# frozen_string_literal: true

module LlmCostTracker
  module Ledger
    module Schema
      module ServiceCharges
        REQUIRED_COLUMNS = %w[
          llm_api_call_id
          charge_id
          component
          unit
          quantity
          rate_amount
          rate_quantity
          cost
          currency
          cost_status
          pricing_basis
          price_key
          price_source
          price_source_version
          source_key
          provider_item_id
          details
        ].freeze

        class << self
          def current_schema_errors
            connection = Ledger::Call.connection
            Ledger::Schema::Adapter.ensure_supported!(connection)
            table_name = Ledger::ServiceCharge.table_name
            unless connection.data_source_exists?(table_name)
              return ["llm_cost_tracker_service_charges table is missing"]
            end

            columns = Ledger::ServiceCharge.columns_hash
            errors = []
            missing = REQUIRED_COLUMNS - columns.keys
            errors << "missing columns: #{missing.join(', ')}" if missing.any?
            errors.concat(json_column_errors(columns, connection))
            unless connection.index_exists?(table_name, :charge_id, unique: true)
              errors << "missing unique index: charge_id"
            end
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
