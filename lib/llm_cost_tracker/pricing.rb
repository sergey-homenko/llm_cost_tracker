# frozen_string_literal: true

require_relative "pricing/lookup"
require_relative "pricing/effective_prices"
require_relative "pricing/explainer"

module LlmCostTracker
  module Pricing
    PRICES = PriceRegistry.builtin_prices

    class << self
      def cost_for(provider:, model:, input_tokens:, output_tokens:, cache_read_input_tokens: 0,
                   cache_write_input_tokens: 0, pricing_mode: nil)
        prices = lookup(provider: provider, model: model)
        return nil unless prices

        usage = UsageBreakdown.build(
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          cache_read_input_tokens: cache_read_input_tokens,
          cache_write_input_tokens: cache_write_input_tokens
        )
        costs = calculate_costs(usage, prices, pricing_mode: pricing_mode)
        return nil unless costs

        Cost.new(
          input_cost: costs[:input].round(8),
          cache_read_input_cost: costs[:cache_read_input].round(8),
          cache_write_input_cost: costs[:cache_write_input].round(8),
          output_cost: costs[:output].round(8),
          total_cost: costs.values.sum.round(8),
          currency: "USD"
        )
      end

      def lookup(provider:, model:)
        Lookup.call(provider: provider, model: model)&.prices
      end

      def explain(provider:, model:, input_tokens: 1, output_tokens: 1, cache_read_input_tokens: 0,
                  cache_write_input_tokens: 0, pricing_mode: nil)
        Explainer.call(
          provider: provider,
          model: model,
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          cache_read_input_tokens: cache_read_input_tokens,
          cache_write_input_tokens: cache_write_input_tokens,
          pricing_mode: pricing_mode
        )
      end

      private

      def calculate_costs(usage, prices, pricing_mode:)
        effective = EffectivePrices.call(usage: usage, prices: prices, pricing_mode: pricing_mode)
        return nil unless effective.complete?

        {
          input: token_cost(usage.input_tokens, effective.input),
          cache_read_input: token_cost(usage.cache_read_input_tokens, effective.cache_read_input),
          cache_write_input: token_cost(usage.cache_write_input_tokens, effective.cache_write_input),
          output: token_cost(usage.output_tokens, effective.output)
        }
      end

      def token_cost(tokens, per_million_price)
        return 0.0 if tokens.to_i.zero?
        return nil if per_million_price.nil?

        (tokens.to_f / 1_000_000) * per_million_price
      end
    end
  end
end
