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
      def matched?
        !prices.nil?
      end

      def complete?
        matched? && missing_price_keys.empty?
      end

      def message
        return "No price entry matched #{provider}/#{model}" unless matched?
        return "Matched #{matched_key} from #{source} via #{matched_by}" if complete?

        "Matched #{matched_key} from #{source} via #{matched_by}, but missing #{missing_price_keys.join(', ')}"
      end
    end

    module Explainer
      class << self
        def call(provider:, model:, token_usage:, pricing_mode: nil)
          match = Lookup.call(provider: provider, model: model)

          explanation(provider, model, pricing_mode, match, token_usage)
        end

        private

        def explanation(provider, model, pricing_mode, match, usage)
          prices = match&.prices
          pricing_mode = Pricing.normalize_mode(pricing_mode)
          effective = if prices && usage
                        EffectivePrices.call(usage: usage, prices: prices, pricing_mode: pricing_mode)
                      end

          Explanation.new(
            provider.to_s,
            model.to_s,
            pricing_mode,
            match&.source,
            match&.key,
            match&.matched_by,
            prices,
            effective || {},
            effective ? effective.filter_map { |key, value| key if value.nil? } : []
          )
        end
      end
    end
  end
end
