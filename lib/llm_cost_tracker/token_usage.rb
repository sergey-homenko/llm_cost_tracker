# frozen_string_literal: true

require "active_support/core_ext/hash/keys"

module LlmCostTracker
  TokenUsage = Data.define(
    :input_tokens,
    :cache_read_input_tokens,
    :cache_write_input_tokens,
    :cache_write_1h_input_tokens,
    :output_tokens,
    :total_tokens,
    :hidden_output_tokens
  ) do
    def self.build(input_tokens:, output_tokens:, cache_read_input_tokens: 0,
                   cache_write_input_tokens: 0, cache_write_1h_input_tokens: 0,
                   total_tokens: nil, hidden_output_tokens: 0)
      input = input_tokens.to_i
      output = output_tokens.to_i
      cache_read = cache_read_input_tokens.to_i
      cache_write = cache_write_input_tokens.to_i
      cache_write_1h = cache_write_1h_input_tokens.to_i
      total = total_tokens.nil? ? input + cache_read + cache_write + cache_write_1h + output : total_tokens.to_i

      new(
        input_tokens: input,
        cache_read_input_tokens: cache_read,
        cache_write_input_tokens: cache_write,
        cache_write_1h_input_tokens: cache_write_1h,
        output_tokens: output,
        total_tokens: total,
        hidden_output_tokens: hidden_output_tokens.to_i
      )
    end

    def self.from_hash(attributes)
      attributes = attributes.to_h.symbolize_keys
      build(
        input_tokens: attributes.fetch(:input_tokens, 0),
        output_tokens: attributes.fetch(:output_tokens, 0),
        total_tokens: attributes[:total_tokens],
        cache_read_input_tokens: attributes[:cache_read_input_tokens],
        cache_write_input_tokens: attributes[:cache_write_input_tokens],
        cache_write_1h_input_tokens: attributes[:cache_write_1h_input_tokens],
        hidden_output_tokens: attributes[:hidden_output_tokens]
      )
    end

    def price_quantities
      {
        input: input_tokens,
        cache_read_input: cache_read_input_tokens,
        cache_write_input: cache_write_input_tokens,
        cache_write_1h_input: cache_write_1h_input_tokens,
        output: output_tokens
      }
    end

    def stored_attributes
      to_h.slice(*STORED_KEYS)
    end

    def to_h
      super.compact
    end
  end

  TokenUsage::COUNTER_KEYS = %i[
    input_tokens
    cache_read_input_tokens
    cache_write_input_tokens
    cache_write_1h_input_tokens
    output_tokens
    total_tokens
    hidden_output_tokens
  ].freeze

  TokenUsage::BASE_STORED_KEYS = %i[
    input_tokens
    output_tokens
    total_tokens
  ].freeze

  TokenUsage::OPTIONAL_STORED_KEYS = %i[
    cache_read_input_tokens
    cache_write_input_tokens
    cache_write_1h_input_tokens
    hidden_output_tokens
  ].freeze

  TokenUsage::STORED_KEYS = (TokenUsage::BASE_STORED_KEYS + TokenUsage::OPTIONAL_STORED_KEYS).freeze

  TokenUsage::BASE_DASHBOARD_SUM_KEYS = %i[
    input_tokens
    output_tokens
  ].freeze

  TokenUsage::OPTIONAL_DASHBOARD_SUM_KEYS = %i[
    cache_read_input_tokens
    cache_write_input_tokens
    cache_write_1h_input_tokens
    hidden_output_tokens
  ].freeze

  TokenUsage::DASHBOARD_SUM_KEYS =
    (TokenUsage::BASE_DASHBOARD_SUM_KEYS + TokenUsage::OPTIONAL_DASHBOARD_SUM_KEYS).freeze

  TokenUsage::PRICE_KEYS = %i[
    input
    output
    cache_read_input
    cache_write_input
    cache_write_1h_input
  ].freeze
end
