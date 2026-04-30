# frozen_string_literal: true

require "active_support/core_ext/object/blank"

require_relative "components"

module LlmCostTracker
  module Pricing
    module EffectivePrices
      class << self
        def call(usage:, prices:, pricing_mode:)
          quantities = usage.price_quantities
          context_tier = context_tier?(usage, prices)

          Pricing::COMPONENTS.to_h do |component|
            price_key = component.price_key
            tokens = quantities.fetch(price_key)
            price = tokens.positive? ? price_for(prices, price_key, pricing_mode, context_tier) : 0.0
            [price_key, price]
          end
        end

        private

        def price_for(prices, key, pricing_mode, context_tier)
          mode = pricing_mode.to_s.strip.presence
          mode = nil if mode == "standard"
          return contextual_price(prices, key, context_tier) unless mode

          contextual_price(prices, :"#{mode}_#{key}", context_tier) ||
            derived_batch_price(prices, key, mode, context_tier)
        end

        def contextual_price(prices, key, context_tier)
          return prices[key] unless context_tier

          prices[:"above_context_#{key}"]
        end

        def derived_batch_price(prices, key, mode, context_tier)
          return nil unless mode == "batch"

          standard_price = contextual_price(prices, key, context_tier)
          return nil unless standard_price

          base_key = key == :output ? :output : :input
          batch_key = key == :output ? :batch_output : :batch_input
          base_price = contextual_price(prices, base_key, context_tier)
          batch_price = contextual_price(prices, batch_key, context_tier)
          return nil unless base_price && batch_price

          standard_price * (batch_price.to_f / base_price)
        end

        def context_tier?(usage, prices)
          threshold = prices[:_context_price_threshold_tokens]
          return false unless threshold

          input_tokens = usage.input_tokens +
                         usage.cache_read_input_tokens +
                         usage.cache_write_input_tokens +
                         usage.cache_write_1h_input_tokens
          input_tokens > threshold.to_i
        end
      end
    end
  end
end
