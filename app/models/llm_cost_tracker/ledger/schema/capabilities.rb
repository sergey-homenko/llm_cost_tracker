# frozen_string_literal: true

require "llm_cost_tracker/ledger/schema/adapter"

module LlmCostTracker
  module Ledger
    module Schema
      module Capabilities
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
          tags
          tracked_at
        ].freeze

        def reset_column_information
          remove_instance_variable(:@lct_schema_capabilities) if instance_variable_defined?(:@lct_schema_capabilities)

          super
        end

        def current_schema?
          current_schema_errors.empty?
        end

        def current_schema_errors
          lct_schema_capabilities.fetch(:current_schema_errors)
        end

        def missing_current_schema_columns
          lct_schema_capabilities.fetch(:missing_current_schema_columns)
        end

        private

        def lct_schema_capabilities
          columns = columns_hash
          adapter_name = connection.adapter_name
          cache = @lct_schema_capabilities

          return cache.fetch(:values) if cache && cache.fetch(:columns).equal?(columns) &&
                                         cache.fetch(:adapter_name) == adapter_name

          values = build_lct_schema_capabilities(columns, adapter_name)
          @lct_schema_capabilities = { columns: columns, adapter_name: adapter_name, values: values }
          values
        end

        def build_lct_schema_capabilities(columns, adapter_name)
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

          tag_column = columns["tags"]
          if tag_column
            postgresql = Ledger::Schema::Adapter.postgresql?(adapter_name)
            expected_type = postgresql ? "jsonb" : "json"
            valid_type =
              if postgresql
                tag_column.type == :jsonb || tag_column.sql_type.to_s.downcase == "jsonb"
              else
                tag_column.type == :json
              end

            errors << "tags column must use #{expected_type}" unless valid_type
          end

          errors
        end

        def missing_columns_for(columns)
          CURRENT_SCHEMA_COLUMNS - columns.keys
        end
      end
    end
  end
end
