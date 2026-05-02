# frozen_string_literal: true

module LlmCostTracker
  module Billing
    module Components
      Component = Data.define(:key, :unit, :category, :direction, :modality, :token_key, :cost_key)

      REGISTRY = [
        Component.new(
          key: :input,
          unit: :token,
          category: :token,
          direction: :input,
          modality: :text,
          token_key: :input_tokens,
          cost_key: :input_cost
        ),
        Component.new(
          key: :cache_read_input,
          unit: :token,
          category: :token,
          direction: :input,
          modality: :text,
          token_key: :cache_read_input_tokens,
          cost_key: :cache_read_input_cost
        ),
        Component.new(
          key: :cache_write_input,
          unit: :token,
          category: :token,
          direction: :input,
          modality: :text,
          token_key: :cache_write_input_tokens,
          cost_key: :cache_write_input_cost
        ),
        Component.new(
          key: :cache_write_1h_input,
          unit: :token,
          category: :token,
          direction: :input,
          modality: :text,
          token_key: :cache_write_1h_input_tokens,
          cost_key: :cache_write_1h_input_cost
        ),
        Component.new(
          key: :output,
          unit: :token,
          category: :token,
          direction: :output,
          modality: :text,
          token_key: :output_tokens,
          cost_key: :output_cost
        ),
        Component.new(
          key: :audio_input,
          unit: :token,
          category: :token,
          direction: :input,
          modality: :audio,
          token_key: :audio_input_tokens,
          cost_key: :audio_input_cost
        ),
        Component.new(
          key: :audio_output,
          unit: :token,
          category: :token,
          direction: :output,
          modality: :audio,
          token_key: :audio_output_tokens,
          cost_key: :audio_output_cost
        ),
        Component.new(
          key: :web_search_request,
          unit: :request,
          category: :tool,
          direction: :neither,
          modality: :text,
          token_key: nil,
          cost_key: nil
        ),
        Component.new(
          key: :file_search_call,
          unit: :request,
          category: :tool,
          direction: :neither,
          modality: :text,
          token_key: nil,
          cost_key: nil
        ),
        Component.new(
          key: :container_session,
          unit: :session,
          category: :runtime,
          direction: :neither,
          modality: :none,
          token_key: nil,
          cost_key: nil
        ),
        Component.new(
          key: :code_execution_request,
          unit: :request,
          category: :runtime,
          direction: :neither,
          modality: :none,
          token_key: nil,
          cost_key: nil
        ),
        Component.new(
          key: :code_execution_hour,
          unit: :hour,
          category: :runtime,
          direction: :neither,
          modality: :none,
          token_key: nil,
          cost_key: nil
        ),
        Component.new(
          key: :grounding_request,
          unit: :request,
          category: :tool,
          direction: :neither,
          modality: :text,
          token_key: nil,
          cost_key: nil
        )
      ].freeze

      BY_KEY = REGISTRY.to_h { |component| [component.key, component] }.freeze
      TOKEN_PRICED = REGISTRY.select { |component| component.token_key && component.cost_key }.freeze
    end
  end
end
