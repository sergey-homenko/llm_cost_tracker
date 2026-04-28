# frozen_string_literal: true

require_relative "effective_prices"

module LlmCostTracker
  module Pricing
    Explanation = Data.define(
      :provider,
      :model,
      :pricing_mode,
      :source,
      :matched_key,
      :matched_by,
      :prices,
      :effective_prices,
      :missing_price_keys
    ) do
      def matched? = !prices.nil?

      def complete? = matched? && missing_price_keys.empty?

      def message
        return "No price entry matched #{provider}/#{model}" unless matched?
        return "Matched #{matched_key} from #{source} via #{matched_by}" if complete?

        "Matched #{matched_key} from #{source} via #{matched_by}, but missing #{missing_price_keys.join(', ')}"
      end
    end

    module Explainer
      class << self
        def call(provider:, model:, input_tokens: 1, output_tokens: 1, cache_read_input_tokens: 0,
                 cache_write_input_tokens: 0, pricing_mode: nil)
          match = Lookup.call(provider: provider, model: model)
          usage = match && UsageBreakdown.build(
            input_tokens: input_tokens,
            output_tokens: output_tokens,
            cache_read_input_tokens: cache_read_input_tokens,
            cache_write_input_tokens: cache_write_input_tokens
          )

          explanation(provider, model, pricing_mode, match, usage)
        end

        private

        def explanation(provider, model, pricing_mode, match, usage)
          prices = match&.prices
          effective = if prices && usage
                        EffectivePrices.call(usage: usage, prices: prices, pricing_mode: pricing_mode)
                      end

          Explanation.new(
            provider.to_s,
            model.to_s,
            normalized_pricing_mode(pricing_mode),
            match&.source,
            match&.key,
            match&.matched_by,
            prices,
            effective ? effective.to_h : {},
            effective ? effective.missing_keys : []
          )
        end

        def normalized_pricing_mode(value)
          return nil if value.nil?

          mode = value.to_s.strip
          return nil if mode.empty? || mode == "standard"

          mode
        end
      end
    end
  end
end
