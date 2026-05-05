# frozen_string_literal: true

module LlmCostTracker
  module Billing
    module Components
      Component = Data.define(
        :key,
        :kind,
        :direction,
        :modality,
        :cache_state,
        :unit,
        :category,
        :token_key,
        :cost_key
      )

      REGISTRY = [
        Component.new(
          key: :input,
          kind: :text_token,
          direction: :input,
          modality: :text,
          cache_state: :none,
          unit: :token,
          category: :token,
          token_key: :input_tokens,
          cost_key: :input_cost
        ),
        Component.new(
          key: :cache_read_input,
          kind: :text_token,
          direction: :input,
          modality: :text,
          cache_state: :read,
          unit: :token,
          category: :token,
          token_key: :cache_read_input_tokens,
          cost_key: :cache_read_input_cost
        ),
        Component.new(
          key: :cache_write_input,
          kind: :text_token,
          direction: :input,
          modality: :text,
          cache_state: :write_5m,
          unit: :token,
          category: :token,
          token_key: :cache_write_input_tokens,
          cost_key: :cache_write_input_cost
        ),
        Component.new(
          key: :cache_write_extended_input,
          kind: :text_token,
          direction: :input,
          modality: :text,
          cache_state: :write_1h,
          unit: :token,
          category: :token,
          token_key: :cache_write_extended_input_tokens,
          cost_key: :cache_write_extended_input_cost
        ),
        Component.new(
          key: :output,
          kind: :text_token,
          direction: :output,
          modality: :text,
          cache_state: :none,
          unit: :token,
          category: :token,
          token_key: :output_tokens,
          cost_key: :output_cost
        ),
        Component.new(
          key: :audio_input,
          kind: :audio_token,
          direction: :input,
          modality: :audio,
          cache_state: :none,
          unit: :token,
          category: :token,
          token_key: :audio_input_tokens,
          cost_key: :audio_input_cost
        ),
        Component.new(
          key: :audio_output,
          kind: :audio_token,
          direction: :output,
          modality: :audio,
          cache_state: :none,
          unit: :token,
          category: :token,
          token_key: :audio_output_tokens,
          cost_key: :audio_output_cost
        ),
        Component.new(
          key: :web_search_request,
          kind: :web_search_request,
          direction: :neither,
          modality: :text,
          cache_state: :none,
          unit: :request,
          category: :tool,
          token_key: nil,
          cost_key: nil
        ),
        Component.new(
          key: :file_search_call,
          kind: :file_search_call,
          direction: :neither,
          modality: :text,
          cache_state: :none,
          unit: :request,
          category: :tool,
          token_key: nil,
          cost_key: nil
        ),
        Component.new(
          key: :container_session,
          kind: :container_session,
          direction: :neither,
          modality: :none,
          cache_state: :none,
          unit: :session,
          category: :runtime,
          token_key: nil,
          cost_key: nil
        ),
        Component.new(
          key: :code_execution_request,
          kind: :code_execution_request,
          direction: :neither,
          modality: :none,
          cache_state: :none,
          unit: :request,
          category: :runtime,
          token_key: nil,
          cost_key: nil
        ),
        Component.new(
          key: :code_execution_hour,
          kind: :code_execution_hour,
          direction: :neither,
          modality: :none,
          cache_state: :none,
          unit: :hour,
          category: :runtime,
          token_key: nil,
          cost_key: nil
        ),
        Component.new(
          key: :grounding_request,
          kind: :grounding_request,
          direction: :neither,
          modality: :text,
          cache_state: :none,
          unit: :request,
          category: :tool,
          token_key: nil,
          cost_key: nil
        )
      ].freeze

      BY_KEY = REGISTRY.to_h { |component| [component.key, component] }.freeze
      TOKEN_PRICED = REGISTRY.select { |component| component.token_key && component.cost_key }.freeze
    end
  end
end
