# frozen_string_literal: true

require_relative "base"

module LlmCostTracker
  module Ledger
    module Schema
      module Calls
        extend Base

        REQUIRED_COLUMNS = %w[
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

        class << self
          def model = LlmCostTracker::Call

          private

          def compute_errors(connection, table_name, columns)
            errors = column_errors(columns)
            errors.concat(Adapter.json_column_errors(columns["pricing_snapshot"], connection, "pricing_snapshot"))
            errors.concat(missing_index_errors(connection, table_name))
            errors
          end

          def missing_index_errors(connection, table_name)
            REQUIRED_INDEXES.filter_map do |spec|
              next if connection.index_exists?(table_name, spec[:columns], **spec.except(:columns))

              prefix = spec[:unique] ? "unique " : ""
              "missing #{prefix}index: #{Array(spec[:columns]).join(', ')}"
            end
          end
        end
      end
    end
  end
end
