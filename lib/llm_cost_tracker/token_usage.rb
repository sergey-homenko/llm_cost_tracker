# frozen_string_literal: true

require_relative "billing/components"

module LlmCostTracker
  TokenUsage = Data.define(
    :input_tokens,
    :cache_read_input_tokens,
    :cache_write_input_tokens,
    :cache_write_1h_input_tokens,
    :audio_input_tokens,
    :output_tokens,
    :audio_output_tokens,
    :total_tokens,
    :hidden_output_tokens
  ) do
    def self.build_from_tokens(tokens)
      return tokens if tokens.is_a?(self)

      values = tokens.to_h
      token_attributes = Billing::Components::TOKEN_PRICED.to_h do |component|
        [component.token_key, values.fetch(component.key, 0)]
      end

      build(
        **token_attributes,
        total_tokens: values[:total],
        hidden_output_tokens: values.fetch(:hidden_output, 0)
      )
    end

    def self.build(input_tokens:, output_tokens:, cache_read_input_tokens: 0,
                   cache_write_input_tokens: 0, cache_write_1h_input_tokens: 0,
                   audio_input_tokens: 0, audio_output_tokens: 0,
                   total_tokens: nil, hidden_output_tokens: 0)
      input = input_tokens.to_i
      output = output_tokens.to_i
      cache_read = cache_read_input_tokens.to_i
      cache_write = cache_write_input_tokens.to_i
      cache_write_1h = cache_write_1h_input_tokens.to_i
      audio_input = audio_input_tokens.to_i
      audio_output = audio_output_tokens.to_i
      hidden_output = hidden_output_tokens.to_i
      calculated_total = input + cache_read + cache_write + cache_write_1h + audio_input + output + audio_output
      total = total_tokens.nil? ? calculated_total : [total_tokens.to_i, calculated_total].max

      new(
        input_tokens: input,
        cache_read_input_tokens: cache_read,
        cache_write_input_tokens: cache_write,
        cache_write_1h_input_tokens: cache_write_1h,
        audio_input_tokens: audio_input,
        output_tokens: output,
        audio_output_tokens: audio_output,
        total_tokens: total,
        hidden_output_tokens: hidden_output
      )
    end
  end
end
