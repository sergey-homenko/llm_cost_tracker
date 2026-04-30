# frozen_string_literal: true

module LlmCostTracker
  module Pricing
    Component = Data.define(:price_key, :token_key, :cost_key)

    COMPONENTS = [
      Component.new(
        price_key: :input,
        token_key: :input_tokens,
        cost_key: :input_cost
      ),
      Component.new(
        price_key: :cache_read_input,
        token_key: :cache_read_input_tokens,
        cost_key: :cache_read_input_cost
      ),
      Component.new(
        price_key: :cache_write_input,
        token_key: :cache_write_input_tokens,
        cost_key: :cache_write_input_cost
      ),
      Component.new(
        price_key: :cache_write_1h_input,
        token_key: :cache_write_1h_input_tokens,
        cost_key: :cache_write_1h_input_cost
      ),
      Component.new(
        price_key: :output,
        token_key: :output_tokens,
        cost_key: :output_cost
      )
    ].freeze

    COST_KEYS = (COMPONENTS.map(&:cost_key) + %i[total_cost]).freeze
  end
end
