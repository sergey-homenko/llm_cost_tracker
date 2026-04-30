# frozen_string_literal: true

require_relative "pricing/registry"
require_relative "pricing/lookup"
require_relative "pricing/effective_prices"
require_relative "pricing/explainer"

module LlmCostTracker
  module Pricing
    PRICES = Registry.builtin_prices

    class << self
      def cost_for(provider:, model:, token_usage:, pricing_mode: nil)
        prices = lookup(provider: provider, model: model)
        return nil unless prices

        costs = calculate_costs(token_usage, prices, pricing_mode: pricing_mode)
        return nil unless costs

        values = TokenUsage::PRICED_COMPONENTS.to_h do |component|
          [component.fetch(:cost_key), costs.fetch(component.fetch(:price_key)).round(8)]
        end

        values.merge(total_cost: costs.values.sum.round(8))
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
        return nil if effective.value?(nil)

        usage.price_quantities.to_h do |key, tokens|
          [key, token_cost(tokens, effective.fetch(key))]
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
