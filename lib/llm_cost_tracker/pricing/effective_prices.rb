# frozen_string_literal: true

require "active_support/core_ext/object/blank"

module LlmCostTracker
  module Pricing
    EffectivePriceSet = Data.define(*TokenUsage::PRICE_KEYS) do
      def complete?
        missing_keys.empty?
      end

      def missing_keys
        to_h.filter_map { |key, value| key if value.nil? }
      end
    end

    module EffectivePrices
      class << self
        def call(usage:, prices:, pricing_mode:)
          quantities = usage.price_quantities

          values = TokenUsage::PRICED_COMPONENTS.to_h do |component|
            tokens = quantities.fetch(component.price_key)
            price = if tokens.positive?
                      price_for(prices, component.price_key, pricing_mode) ||
                        (component.fallback_price_key && price_for(prices, component.fallback_price_key, pricing_mode))
                    else
                      0.0
                    end
            [component.price_key, price]
          end

          EffectivePriceSet.new(**values)
        end

        private

        def price_for(prices, key, pricing_mode)
          mode = pricing_mode.to_s.strip.presence
          mode = nil if mode == "standard"
          return prices[key] unless mode

          prices[:"#{mode}_#{key}"] || prices[key]
        end
      end
    end
  end
end
