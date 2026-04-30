# frozen_string_literal: true

module LlmCostTracker
  module TokenUsageHelper
    COMPONENT_LABELS = {
      input_tokens: "Input",
      cache_read_input_tokens: "Cache read",
      cache_write_input_tokens: "Cache write",
      cache_write_1h_input_tokens: "1h cache write",
      output_tokens: "Output",
      hidden_output_tokens: "Hidden output"
    }.freeze
    QUALITY_LABELS = COMPONENT_LABELS.merge(
      input_tokens: "Regular input",
      cache_read_input_tokens: "Cache read input",
      cache_write_input_tokens: "Cache write input",
      cache_write_1h_input_tokens: "1h cache write input"
    ).freeze
    STACK_CLASSES = {
      input_tokens: "lct-stack-fill-input",
      cache_read_input_tokens: "lct-stack-fill-cache-read",
      cache_write_input_tokens: "lct-stack-fill-cache-write",
      cache_write_1h_input_tokens: "lct-stack-fill-cache-write-1h",
      output_tokens: "lct-stack-fill-output"
    }.freeze

    def token_usage_stack_components
      token_usage_display_components(labels: COMPONENT_LABELS).select do |component|
        component.fetch(:cost_key)
      end
    end

    def token_usage_quality_components
      token_usage_display_components(labels: QUALITY_LABELS)
    end

    private

    def token_usage_display_components(labels:)
      LlmCostTracker::TokenUsage::COMPONENTS.map do |component|
        token_key = component.fetch(:token_key)
        component.merge(
          label: labels.fetch(token_key),
          css_class: STACK_CLASSES[token_key]
        )
      end
    end
  end
end
