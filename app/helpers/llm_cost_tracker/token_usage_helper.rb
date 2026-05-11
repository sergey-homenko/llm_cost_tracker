# frozen_string_literal: true

module LlmCostTracker
  module TokenUsageHelper
    COMPONENT_LABELS = {
      input_tokens: "Input",
      cache_read_input_tokens: "Cache read",
      cache_write_input_tokens: "Cache write",
      cache_write_extended_input_tokens: "Extended cache write",
      audio_input_tokens: "Audio input",
      image_input_tokens: "Image input",
      output_tokens: "Output",
      audio_output_tokens: "Audio output",
      image_output_tokens: "Image output",
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
      image_input_tokens: "lct-stack-fill-image-input",
      output_tokens: "lct-stack-fill-output",
      audio_output_tokens: "lct-stack-fill-audio-output",
      image_output_tokens: "lct-stack-fill-image-output"
    }.freeze

    def token_usage_stack_components
      token_usage_display_components(labels: COMPONENT_LABELS).select do |component|
        component.fetch(:cost_key)
      end
    end

    def call_line_item_costs_by_component(call)
      call.line_items.each_with_object({}) do |line_item, accumulator|
        component = LlmCostTracker::Billing::Components::TOKEN_PRICED.find do |item|
          item.kind.to_s == line_item.kind.to_s &&
            item.direction.to_s == line_item.direction.to_s &&
            item.cache_state.to_s == line_item.cache_state.to_s
        end
        accumulator[component.key] = line_item.cost if component && line_item.cost
      end
    end

    private

    def token_usage_display_components(labels:)
      LlmCostTracker::Billing::Components::TOKEN_PRICED.map do |component|
        token_key = component.token_key
        {
          token_key: token_key,
          cost_key: component.cost_key,
          price_key: component.key,
          label: labels.fetch(token_key),
          css_class: STACK_CLASSES[token_key]
        }
      end + [
        {
          token_key: :hidden_output_tokens,
          cost_key: nil,
          price_key: nil,
          label: labels.fetch(:hidden_output_tokens),
          css_class: nil
        }
      ]
    end
  end
end
