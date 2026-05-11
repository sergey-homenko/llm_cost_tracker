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
          cache_write_extended_input_tokens
          audio_input_tokens
          audio_output_tokens
          image_input_tokens
          image_output_tokens
          hidden_output_tokens
          total_cost
          latency_ms
          stream
          usage_source
          provider_response_id
          provider_project_id
          provider_api_key_id
          provider_workspace_id
          batch
          pricing_mode
          cost_status
          pricing_snapshot
          tracked_at
        ].freeze

        REQUIRED_INDEXES = [
          { columns: :event_id, unique: true },
          { columns: :tracked_at },
          { columns: %i[provider tracked_at] },
          { columns: %i[model tracked_at] },
          { columns: :cost_status },
          { columns: :provider_response_id }
        ].freeze
        private_constant :REQUIRED_INDEXES

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
            columns = LlmCostTracker::Call.columns_hash
            adapter_name = LlmCostTracker::Call.connection.adapter_name
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
            errors.concat(Adapter.json_column_errors(columns["pricing_snapshot"], adapter_name, "pricing_snapshot"))
            errors.concat(missing_index_errors)
            errors
          end

          def missing_index_errors
            connection = LlmCostTracker::Call.connection
            REQUIRED_INDEXES.filter_map do |spec|
              next if connection.index_exists?(LlmCostTracker::Call.table_name, spec[:columns], **spec.except(:columns))

              prefix = spec[:unique] ? "unique " : ""
              "missing #{prefix}index: #{Array(spec[:columns]).join(', ')}"
            end
          rescue StandardError
            []
          end

          def missing_columns_for(columns)
            CURRENT_SCHEMA_COLUMNS - columns.keys
          end
        end
      end
    end
  end
end
