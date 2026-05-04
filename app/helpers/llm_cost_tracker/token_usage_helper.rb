# frozen_string_literal: true

module LlmCostTracker
  module TokenUsageHelper
    COMPONENT_LABELS = {
      input_tokens: "Input",
      cache_read_input_tokens: "Cache read",
      cache_write_input_tokens: "Cache write",
      cache_write_extended_input_tokens: "Extended cache write",
      audio_input_tokens: "Audio input",
      output_tokens: "Output",
      audio_output_tokens: "Audio output",
      hidden_output_tokens: "Hidden output"
    }.freeze
    QUALITY_LABELS = COMPONENT_LABELS.merge(
      input_tokens: "Regular input",
      cache_read_input_tokens: "Cache read input",
      cache_write_input_tokens: "Cache write input",
      cache_write_extended_input_tokens: "Extended cache write input"
    ).freeze
    STACK_CLASSES = {
      input_tokens: "lct-stack-fill-input",
      cache_read_input_tokens: "lct-stack-fill-cache-read",
      cache_write_input_tokens: "lct-stack-fill-cache-write",
      cache_write_extended_input_tokens: "lct-stack-fill-cache-write-extended",
      audio_input_tokens: "lct-stack-fill-audio-input",
      output_tokens: "lct-stack-fill-output",
      audio_output_tokens: "lct-stack-fill-audio-output"
    }.freeze

    def token_usage_stack_components
      token_usage_display_components(labels: COMPONENT_LABELS).select do |component|
        component.fetch(:cost_key)
      end
    end

    private

    def token_usage_display_components(labels:)
      LlmCostTracker::Billing::Components::TOKEN_PRICED.map do |component|
        token_key = component.token_key
        {
          token_key: token_key,
          cost_key: component.cost_key,
          label: labels.fetch(token_key),
          css_class: STACK_CLASSES[token_key]
        }
      end + [
        {
          token_key: :hidden_output_tokens,
          cost_key: nil,
          label: labels.fetch(:hidden_output_tokens),
          css_class: nil
        }
      ]
    end
  end
end
