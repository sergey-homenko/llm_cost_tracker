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

          EffectivePriceSet.new(
            input: price_for_usage(quantities.fetch(:input), prices, :input, pricing_mode),
            cache_read_input: price_for_cache_usage(
              quantities.fetch(:cache_read_input),
              prices,
              :cache_read_input,
              pricing_mode
            ),
            cache_write_input: price_for_cache_usage(
              quantities.fetch(:cache_write_input),
              prices,
              :cache_write_input,
              pricing_mode
            ),
            cache_write_1h_input: price_for_usage(
              quantities.fetch(:cache_write_1h_input),
              prices,
              :cache_write_1h_input,
              pricing_mode
            ),
            output: price_for_usage(quantities.fetch(:output), prices, :output, pricing_mode)
          )
        end

        private

        def price_for_cache_usage(tokens, prices, key, pricing_mode)
          return 0.0 unless tokens.positive?

          price_for(prices, key, pricing_mode) || price_for(prices, :input, pricing_mode)
        end

        def price_for_usage(tokens, prices, key, pricing_mode)
          tokens.positive? ? price_for(prices, key, pricing_mode) : 0.0
        end

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
