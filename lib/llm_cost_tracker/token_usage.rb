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
      values = TokenUsage::COMPONENTS.to_h do |component|
        [component.token_key, attributes[component.token_key]]
      end
      build(
        **values,
        total_tokens: attributes[:total_tokens]
      )
    end

    def price_quantities
      self.class::PRICED_COMPONENTS.to_h do |component|
        [component.price_key, public_send(component.token_key)]
      end
    end

    def stored_attributes
      to_h.slice(*STORED_KEYS)
    end

    def to_h
      super.compact
    end
  end

  TokenUsage::Component = Data.define(
    :price_key, :token_key, :cost_key, :label, :dashboard_label, :css_class, :stored, :fallback_price_key
  )

  TokenUsage::COMPONENTS = [
    [:input, :input_tokens, :input_cost, "Input", "Regular input", "lct-stack-fill-input", :base, nil],
    [
      :cache_read_input, :cache_read_input_tokens, :cache_read_input_cost, "Cache read", "Cache read input",
      "lct-stack-fill-cache-read", :optional, :input
    ],
    [
      :cache_write_input, :cache_write_input_tokens, :cache_write_input_cost, "Cache write", "Cache write input",
      "lct-stack-fill-cache-write", :optional, :input
    ],
    [
      :cache_write_1h_input, :cache_write_1h_input_tokens, :cache_write_1h_input_cost, "1h cache write",
      "1h cache write input", "lct-stack-fill-cache-write-1h", :optional, nil
    ],
    [:output, :output_tokens, :output_cost, "Output", "Output", "lct-stack-fill-output", :base, nil],
    [nil, :hidden_output_tokens, nil, "Hidden output", "Hidden output", "lct-stack-fill-output", :optional, nil]
  ].map { |attributes| TokenUsage::Component.new(*attributes) }.freeze

  TokenUsage::PRICED_COMPONENTS = TokenUsage::COMPONENTS.select(&:price_key).freeze
  TokenUsage::BASE_COMPONENTS = TokenUsage::COMPONENTS.select { |component| component.stored == :base }.freeze
  TokenUsage::OPTIONAL_COMPONENTS = TokenUsage::COMPONENTS.select { |component| component.stored == :optional }.freeze
  TokenUsage::BASE_PRICED_COMPONENTS =
    TokenUsage::PRICED_COMPONENTS.select { |component| component.stored == :base }.freeze
  TokenUsage::OPTIONAL_PRICED_COMPONENTS =
    TokenUsage::PRICED_COMPONENTS.select { |component| component.stored == :optional }.freeze

  TokenUsage::COUNTER_KEYS = (TokenUsage::PRICED_COMPONENTS.map(&:token_key) + %i[
    total_tokens
    hidden_output_tokens
  ]).freeze

  TokenUsage::BASE_STORED_KEYS = (TokenUsage::BASE_COMPONENTS.map(&:token_key) + [:total_tokens]).freeze
  TokenUsage::OPTIONAL_STORED_KEYS = TokenUsage::OPTIONAL_COMPONENTS.map(&:token_key).freeze
  TokenUsage::STORED_KEYS = (TokenUsage::BASE_STORED_KEYS + TokenUsage::OPTIONAL_STORED_KEYS).freeze

  TokenUsage::BASE_DASHBOARD_SUM_KEYS = TokenUsage::BASE_COMPONENTS.map(&:token_key).freeze
  TokenUsage::OPTIONAL_DASHBOARD_SUM_KEYS = TokenUsage::OPTIONAL_COMPONENTS.map(&:token_key).freeze
  TokenUsage::DASHBOARD_SUM_KEYS =
    (TokenUsage::BASE_DASHBOARD_SUM_KEYS + TokenUsage::OPTIONAL_DASHBOARD_SUM_KEYS).freeze

  TokenUsage::PRICE_KEYS = TokenUsage::PRICED_COMPONENTS.map(&:price_key).freeze
end
