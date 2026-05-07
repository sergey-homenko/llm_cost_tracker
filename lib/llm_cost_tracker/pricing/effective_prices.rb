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
          return contextual_price(prices: prices, key: key, context_tier: context_tier) unless pricing_mode

          orderings = mode_orderings_for(pricing_mode)
          orderings.each do |mode|
            direct = contextual_price(prices: prices, key: :"#{mode}_#{key}", context_tier: context_tier)
            return direct if direct
          end
          return nil if %i[input output].include?(key)

          derived_mode_price(prices: prices, key: key, modes: orderings, context_tier: context_tier)
        end

        def mode_orderings_for(pricing_mode)
          mode_string = pricing_mode.to_s
          return [mode_string] unless mode_string.include?("_")

          tokens = tokenize_mode(mode_string)
          return [mode_string] if tokens.size <= 1

          [mode_string, *tokens.permutation.map { |permutation| permutation.join("_") }].uniq
        end

        def tokenize_mode(mode_string)
          remaining = mode_string.dup
          tokens = []
          loop do
            break if remaining.empty?

            compound = COMPOUND_MODE_TOKENS.find { |token| remaining == token || remaining.start_with?("#{token}_") }
            if compound
              tokens << compound
              remaining = remaining.delete_prefix(compound).delete_prefix("_")
            else
              first, _, rest = remaining.partition("_")
              tokens << first
              remaining = rest
            end
          end
          tokens
        end

        COMPOUND_MODE_TOKENS = %w[data_residency].freeze
        private_constant :COMPOUND_MODE_TOKENS

        def contextual_price(prices:, key:, context_tier:)
          return prices[key] unless context_tier

          prices[:"above_context_#{key}"]
        end

        def derived_mode_price(prices:, key:, modes:, context_tier:)
          standard_price = contextual_price(prices: prices, key: key, context_tier: context_tier)
          base_price = contextual_price(prices: prices, key: :input, context_tier: context_tier)
          return nil unless standard_price && base_price
          return nil if base_price.zero?

          modes.each do |mode|
            mode_base_price = contextual_price(prices: prices, key: :"#{mode}_input", context_tier: context_tier)
            return standard_price * (mode_base_price / base_price) if mode_base_price
          end
          nil
        end

        def context_tier?(usage:, prices:)
          threshold = prices[:_context_price_threshold_tokens]
          return false unless threshold

          input_tokens = usage.input_tokens +
                         usage.cache_read_input_tokens +
                         usage.cache_write_input_tokens +
                         usage.cache_write_extended_input_tokens +
                         usage.audio_input_tokens
          input_tokens > threshold
        end
      end
    end
  end
end
