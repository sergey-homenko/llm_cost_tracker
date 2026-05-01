# frozen_string_literal: true

require "llm_cost_tracker/ledger/schema/adapter"

module LlmCostTracker
  module Ledger
    module Schema
      module Calls
        CURRENT_SCHEMA_COLUMNS = %w[
          event_id
          provider
          model
          input_tokens
          output_tokens
          total_tokens
          cache_read_input_tokens
          cache_write_input_tokens
          cache_write_1h_input_tokens
          hidden_output_tokens
          input_cost
          output_cost
          total_cost
          cache_read_input_cost
          cache_write_input_cost
          cache_write_1h_input_cost
          latency_ms
          stream
          usage_source
          provider_response_id
          pricing_mode
          cost_status
          pricing_snapshot
          tags
          tracked_at
        ].freeze

        class << self
          def current_schema?
            current_schema_errors.empty?
          end

          def current_schema_errors
            schema_capabilities.fetch(:current_schema_errors)
          end

          def missing_current_schema_columns
            schema_capabilities.fetch(:missing_current_schema_columns)
          end

          private

          def schema_capabilities
            columns = Ledger::Call.columns_hash
            adapter_name = Ledger::Call.connection.adapter_name
            cache = @schema_capabilities

            return cache.fetch(:values) if cache && cache.fetch(:columns).equal?(columns) &&
                                           cache.fetch(:adapter_name) == adapter_name

            values = build_schema_capabilities(columns, adapter_name)
            @schema_capabilities = { columns: columns, adapter_name: adapter_name, values: values }
            values
          end

          def build_schema_capabilities(columns, adapter_name)
            Ledger::Schema::Adapter.ensure_supported!(adapter_name)

            {
              missing_current_schema_columns: missing_columns_for(columns),
              current_schema_errors: schema_errors_for(columns, adapter_name)
            }
          end

          def schema_errors_for(columns, adapter_name)
            errors = []
            missing = missing_columns_for(columns)
            errors << "missing columns: #{missing.join(', ')}" if missing.any?
            errors.concat(json_column_errors(columns, adapter_name, "tags"))
            errors.concat(json_column_errors(columns, adapter_name, "pricing_snapshot"))
            errors
          end

          def json_column_errors(columns, adapter_name, name)
            column = columns[name]
            return [] unless column

            expected_type = Ledger::Schema::Adapter.postgresql?(adapter_name) ? "jsonb" : "json"
            valid_type = json_column_type?(column, adapter_name)
            valid_type ? [] : ["#{name} column must use #{expected_type}"]
          end

          def json_column_type?(column, adapter_name)
            if Ledger::Schema::Adapter.postgresql?(adapter_name)
              column.type == :jsonb || column.sql_type.to_s.downcase == "jsonb"
            else
              column.type == :json
            end
          end

          def missing_columns_for(columns)
            CURRENT_SCHEMA_COLUMNS - columns.keys
          end
        end
      end
    end
  end
end
