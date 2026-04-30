# frozen_string_literal: true

require_relative "pricing/lookup"
require_relative "pricing/effective_prices"
require_relative "pricing/explainer"

module LlmCostTracker
  module Pricing
    PRICES = PriceRegistry.builtin_prices

    class << self
      def cost_for(provider:, model:, token_usage:, pricing_mode: nil)
        prices = lookup(provider: provider, model: model)
        return nil unless prices

        costs = calculate_costs(token_usage, prices, pricing_mode: pricing_mode)
        return nil unless costs

        Cost.new(
          input_cost: costs[:input].round(8),
          cache_read_input_cost: costs[:cache_read_input].round(8),
          cache_write_input_cost: costs[:cache_write_input].round(8),
          cache_write_1h_input_cost: costs[:cache_write_1h_input].round(8),
          output_cost: costs[:output].round(8),
          total_cost: costs.values.sum.round(8),
          currency: "USD"
        )
      end

      def lookup(provider:, model:)
        Lookup.call(provider: provider, model: model)&.prices
      end

      def explain(provider:, model:, token_usage:, pricing_mode: nil)
        Explainer.call(
          provider: provider,
          model: model,
          token_usage: token_usage,
          pricing_mode: pricing_mode
        )
      end

      private

      def calculate_costs(usage, prices, pricing_mode:)
        effective = EffectivePrices.call(usage: usage, prices: prices, pricing_mode: pricing_mode)
        return nil unless effective.complete?

        prices = effective.to_h
        usage.price_quantities.to_h do |key, tokens|
          [key, token_cost(tokens, prices.fetch(key))]
        end
      end

      def token_cost(tokens, per_million_price)
        return 0.0 if tokens.to_i.zero?
        return nil if per_million_price.nil?

        (tokens.to_f / 1_000_000) * per_million_price
      end
    end
  end
end
