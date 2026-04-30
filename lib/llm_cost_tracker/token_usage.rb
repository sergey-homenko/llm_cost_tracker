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
      calculated_total = input + cache_read + cache_write + cache_write_1h + output
      total = total_tokens.nil? ? calculated_total : [total_tokens.to_i, calculated_total].max

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
      values = TokenUsage::COMPONENTS.to_h do |component|
        token_key = component.fetch(:token_key)
        [token_key, attributes[token_key]]
      end
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
        output: output_tokens
      }
    end

    def stored_attributes
      to_h.slice(*self.class::STORED_KEYS)
    end

    def self.stored_cost_attributes(attributes)
      attributes.to_h.symbolize_keys.slice(*TokenUsage::STORED_COST_KEYS).compact
    end

    def to_h
      super.compact
    end
  end

  TokenUsage::COMPONENTS = [
    { price_key: :input, token_key: :input_tokens, cost_key: :input_cost, stored: :base },
    {
      price_key: :cache_read_input,
      token_key: :cache_read_input_tokens,
      cost_key: :cache_read_input_cost,
      stored: :optional
    },
    {
      price_key: :cache_write_input,
      token_key: :cache_write_input_tokens,
      cost_key: :cache_write_input_cost,
      stored: :optional
    },
    {
      price_key: :cache_write_1h_input,
      token_key: :cache_write_1h_input_tokens,
      cost_key: :cache_write_1h_input_cost,
      stored: :optional
    },
    { price_key: :output, token_key: :output_tokens, cost_key: :output_cost, stored: :base },
    { price_key: nil, token_key: :hidden_output_tokens, cost_key: nil, stored: :optional }
  ].map(&:freeze).freeze

  TokenUsage::PRICED_COMPONENTS = TokenUsage::COMPONENTS.select { |component| component.fetch(:price_key) }.freeze
  TokenUsage::BASE_COMPONENTS = TokenUsage::COMPONENTS.select { |component| component.fetch(:stored) == :base }.freeze
  TokenUsage::OPTIONAL_COMPONENTS =
    TokenUsage::COMPONENTS.select { |component| component.fetch(:stored) == :optional }.freeze
  TokenUsage::BASE_PRICED_COMPONENTS =
    TokenUsage::PRICED_COMPONENTS.select { |component| component.fetch(:stored) == :base }.freeze
  TokenUsage::OPTIONAL_PRICED_COMPONENTS =
    TokenUsage::PRICED_COMPONENTS.select { |component| component.fetch(:stored) == :optional }.freeze

  TokenUsage::COUNTER_KEYS = (TokenUsage::PRICED_COMPONENTS.map { |component| component.fetch(:token_key) } + %i[
    total_tokens
    hidden_output_tokens
  ]).freeze

  TokenUsage::BASE_STORED_KEYS = (TokenUsage::BASE_COMPONENTS.map { |component| component.fetch(:token_key) } +
    [:total_tokens]).freeze
  TokenUsage::OPTIONAL_STORED_KEYS =
    TokenUsage::OPTIONAL_COMPONENTS.map { |component| component.fetch(:token_key) }.freeze
  TokenUsage::STORED_KEYS = (TokenUsage::BASE_STORED_KEYS + TokenUsage::OPTIONAL_STORED_KEYS).freeze

  TokenUsage::BASE_COST_KEYS = (TokenUsage::BASE_PRICED_COMPONENTS.map { |component| component.fetch(:cost_key) } +
    [:total_cost]).freeze
  TokenUsage::OPTIONAL_COST_KEYS =
    TokenUsage::OPTIONAL_PRICED_COMPONENTS.map { |component| component.fetch(:cost_key) }.freeze
  TokenUsage::STORED_COST_KEYS = (TokenUsage::BASE_COST_KEYS + TokenUsage::OPTIONAL_COST_KEYS).freeze
end
