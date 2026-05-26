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

        JSON_COLUMNS = %i[pricing_snapshot].freeze

        REQUIRED_INDEXES = [
          { columns: :event_id, unique: true },
          { columns: :tracked_at },
          { columns: %i[provider tracked_at] },
          { columns: %i[model tracked_at] },
          { columns: :cost_status },
          { columns: :provider_response_id }
        ].freeze

        def self.model = LlmCostTracker::Call
      end
    end
  end
end
