# frozen_string_literal: true

require_relative "../billing/components"

module LlmCostTracker
  module Pricing
    module EffectivePrices
      class << self
        def call(usage:, prices:, pricing_mode:)
          context_tier = context_tier?(usage: usage, prices: prices)

          Billing::Components::TOKEN_PRICED.to_h do |component|
            price_key = component.key
            tokens = usage.public_send(component.token_key)
            price = if tokens.positive?
                      price_for(
                        prices: prices,
                        key: price_key,
                        pricing_mode: pricing_mode,
                        context_tier: context_tier
                      )
                    else
                      0.0
                    end
            [price_key, price]
          end
        end

        private

        def price_for(prices:, key:, pricing_mode:, context_tier:)
          mode = Pricing.normalize_mode(pricing_mode)
          return contextual_price(prices: prices, key: key, context_tier: context_tier) unless mode

          contextual_price(prices: prices, key: :"#{mode}_#{key}", context_tier: context_tier) ||
            derived_mode_price(prices: prices, key: key, mode: mode, context_tier: context_tier)
        end

        def contextual_price(prices:, key:, context_tier:)
          return prices[key] unless context_tier

          prices[:"above_context_#{key}"]
        end

        def derived_mode_price(prices:, key:, mode:, context_tier:)
          standard_price = contextual_price(prices: prices, key: key, context_tier: context_tier)
          return nil unless standard_price

          base_key = key == :output ? :output : :input
          base_price = contextual_price(prices: prices, key: base_key, context_tier: context_tier)
          mode_base_price = contextual_price(
            prices: prices,
            key: :"#{mode}_#{base_key}",
            context_tier: context_tier
          )
          return nil unless base_price && mode_base_price

          standard_price * (mode_base_price / base_price)
        end

        def context_tier?(usage:, prices:)
          threshold = prices[:_context_price_threshold_tokens]
          return false unless threshold

          input_tokens = usage.input_tokens +
                         usage.cache_read_input_tokens +
                         usage.cache_write_input_tokens +
                         usage.cache_write_1h_input_tokens +
                         usage.audio_input_tokens
          input_tokens > threshold
        end
      end
    end
  end
end
