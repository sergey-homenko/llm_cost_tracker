# frozen_string_literal: true

require "active_support/core_ext/hash/keys"

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
        hidden_output_tokens: hidden_output_tokens.to_i
      )
    end

    def self.from_hash(attributes)
      attributes = attributes.to_h.symbolize_keys
      values = TokenUsage::COMPONENT_TOKEN_KEYS.to_h { |key| [key, attributes[key]] }
      build(
        **values,
        total_tokens: attributes[:total_tokens]
      )
    end

    def price_quantities
      {
        input: input_tokens,
        cache_read_input: cache_read_input_tokens,
        cache_write_input: cache_write_input_tokens,
        cache_write_1h_input: cache_write_1h_input_tokens,
        audio_input: audio_input_tokens,
        output: output_tokens,
        audio_output: audio_output_tokens
      }
    end

    def stored_attributes
      to_h.slice(*self.class::STORED_KEYS)
    end

    def to_h
      super.compact
    end
  end

  TokenUsage::STORED_KEYS = TokenUsage.members.freeze
  TokenUsage::COMPONENT_TOKEN_KEYS = (TokenUsage.members - %i[total_tokens]).freeze
end
