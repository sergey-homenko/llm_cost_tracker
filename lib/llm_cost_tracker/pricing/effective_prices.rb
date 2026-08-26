# frozen_string_literal: true

require "bigdecimal/util"

require_relative "mode"
require_relative "price_key"

module LlmCostTracker
  module Pricing
    module EffectivePrices
      Resolved = Data.define(:amount, :key)

      class << self
        def call(usage:, quantities:, prices:, pricing_mode:)
          context_tier = context_tier?(usage: usage, prices: prices)
          orderings = pricing_mode && Mode.permutations_for(pricing_mode)

          quantities.to_h do |price_key, tokens|
            resolved = if tokens.positive?
                         price_for(
                           prices: prices,
                           key: price_key,
                           orderings: orderings,
                           context_tier: context_tier
                         )
                       else
                         Resolved.new(amount: BigDecimal("0"), key: price_key)
                       end
            [price_key, resolved]
          end
        end

        private

        def price_for(prices:, key:, orderings:, context_tier:)
          unless orderings
            standard = PriceKey.build(key, above_context: context_tier)
            return resolve(prices[standard], standard)
          end

          orderings.each do |mode|
            table_key = PriceKey.build(key, mode: mode, above_context: context_tier)
            direct = prices[table_key]
            return resolve(direct, table_key) if direct
          end
          return nil if %w[input output].include?(key)

          derived = derived_mode_price(prices: prices, key: key, modes: orderings, context_tier: context_tier)
          resolve(derived, nil)
        end

        def resolve(amount, key)
          amount && Resolved.new(amount: amount, key: key)
        end

        def derived_mode_price(prices:, key:, modes:, context_tier:)
          standard_price = prices[PriceKey.build(key, above_context: context_tier)]
          base_price = prices[PriceKey.build("input", above_context: context_tier)]
          return nil unless standard_price && base_price
          return nil if base_price.zero?

          modes.each do |mode|
            mode_base_price = prices[PriceKey.build("input", mode: mode, above_context: context_tier)]
            next unless mode_base_price

            return standard_price.to_d * mode_base_price.to_d / base_price.to_d
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
