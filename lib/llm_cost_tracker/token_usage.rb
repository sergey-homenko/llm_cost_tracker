# frozen_string_literal: true

require_relative "billing/components"

module LlmCostTracker
  TokenUsage = Data.define(
    :input_tokens,
    :cache_read_input_tokens,
    :cache_write_input_tokens,
    :cache_write_extended_input_tokens,
    :audio_input_tokens,
    :output_tokens,
    :audio_output_tokens,
    :total_tokens,
    :hidden_output_tokens
  ) do
    def self.build_from_tokens(tokens)
      return tokens if tokens.is_a?(self)

      values = tokens.to_h.transform_keys { |key| key.is_a?(Symbol) ? key : key.to_s.to_sym }
      token_attributes = Billing::Components::TOKEN_PRICED.to_h do |component|
        [component.token_key, values.fetch(component.key, 0)]
      end

      build(
        **token_attributes,
        total_tokens: values[:total],
        hidden_output_tokens: values.fetch(:hidden_output, 0)
      )
    end

    def self.non_negative_int(value)
      [value.to_i, 0].max
    end

    def self.build(input_tokens:, output_tokens:, cache_read_input_tokens: 0,
                   cache_write_input_tokens: 0, cache_write_extended_input_tokens: 0,
                   audio_input_tokens: 0, audio_output_tokens: 0,
                   total_tokens: nil, hidden_output_tokens: 0)
      input = non_negative_int(input_tokens)
      output = non_negative_int(output_tokens)
      cache_read = non_negative_int(cache_read_input_tokens)
      cache_write = non_negative_int(cache_write_input_tokens)
      cache_write_extended = non_negative_int(cache_write_extended_input_tokens)
      audio_input = non_negative_int(audio_input_tokens)
      audio_output = non_negative_int(audio_output_tokens)
      hidden_output = non_negative_int(hidden_output_tokens)
      calculated_total = input + cache_read + cache_write + cache_write_extended + audio_input + output + audio_output
      total = total_tokens.nil? ? calculated_total : [non_negative_int(total_tokens), calculated_total].max

      new(
        input_tokens: input,
        cache_read_input_tokens: cache_read,
        cache_write_input_tokens: cache_write,
        cache_write_extended_input_tokens: cache_write_extended,
        audio_input_tokens: audio_input,
        output_tokens: output,
        audio_output_tokens: audio_output,
        total_tokens: total,
        hidden_output_tokens: hidden_output
      )
    end
  end
end
