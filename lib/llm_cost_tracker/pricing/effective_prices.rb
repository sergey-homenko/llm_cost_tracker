# frozen_string_literal: true

require "bigdecimal"

require_relative "../billing/components"
require_relative "mode"

module LlmCostTracker
  module Pricing
    module EffectivePrices
      class << self
        def call(usage:, quantities:, prices:, pricing_mode:)
          context_tier = context_tier?(usage: usage, prices: prices)
          orderings = pricing_mode && Mode.permutations_for(pricing_mode)

          quantities.to_h do |price_key, tokens|
            price = if tokens.positive?
                      price_for(
                        prices: prices,
                        key: price_key,
                        orderings: orderings,
                        context_tier: context_tier
                      )
                    else
                      0.0
                    end
            [price_key, price]
          end
        end

        private

        def price_for(prices:, key:, orderings:, context_tier:)
          return contextual_price(prices: prices, key: key, context_tier: context_tier) unless orderings

          orderings.each do |mode|
            direct = contextual_price(prices: prices, key: "#{mode}_#{key}", context_tier: context_tier)
            return direct if direct
          end
          return nil if %w[input output].include?(key)

          derived_mode_price(prices: prices, key: key, modes: orderings, context_tier: context_tier)
        end

        def contextual_price(prices:, key:, context_tier:)
          return prices[key] unless context_tier

          prices["above_context_#{key}"]
        end

        def derived_mode_price(prices:, key:, modes:, context_tier:)
          standard_price = contextual_price(prices: prices, key: key, context_tier: context_tier)
          base_price = contextual_price(prices: prices, key: "input", context_tier: context_tier)
          return nil unless standard_price && base_price
          return nil if base_price.zero?

          modes.each do |mode|
            mode_base_price = contextual_price(prices: prices, key: "#{mode}_input", context_tier: context_tier)
            next unless mode_base_price

            return BigDecimal(standard_price.to_s) * BigDecimal(mode_base_price.to_s) / BigDecimal(base_price.to_s)
          end
          nil
        end

        def context_tier?(usage:, prices:)
          threshold = prices[Registry::CONTEXT_THRESHOLD_KEY]
          return false unless threshold

          input_tokens = usage.input_tokens +
                         usage.cache_read_input_tokens +
                         usage.cache_write_input_tokens +
                         usage.cache_write_extended_input_tokens +
                         usage.audio_input_tokens +
                         usage.image_input_tokens
          input_tokens > threshold
        end
      end
    end
  end
end
