# frozen_string_literal: true

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
          effective = prices && usage ? effective_prices(usage, prices, pricing_mode) : {}
          missing = prices && usage ? missing_price_keys(effective) : []

          Explanation.new(
            provider.to_s,
            model.to_s,
            normalized_pricing_mode(pricing_mode),
            match&.source,
            match&.key,
            match&.matched_by,
            prices,
            effective,
            missing
          )
        end

        def effective_prices(usage, prices, pricing_mode)
          {
            input: price_for_usage(usage.input_tokens, prices, :input, pricing_mode),
            cache_read_input: price_for_cache_usage(usage.cache_read_input_tokens, prices, :cache_read_input,
                                                    pricing_mode),
            cache_write_input: price_for_cache_usage(usage.cache_write_input_tokens, prices, :cache_write_input,
                                                     pricing_mode),
            output: price_for_usage(usage.output_tokens, prices, :output, pricing_mode)
          }
        end

        def price_for_cache_usage(tokens, prices, key, pricing_mode)
          return 0.0 unless tokens.positive?

          price_for(prices, key, pricing_mode) || price_for(prices, :input, pricing_mode)
        end

        def price_for_usage(tokens, prices, key, pricing_mode)
          tokens.positive? ? price_for(prices, key, pricing_mode) : 0.0
        end

        def price_for(prices, key, pricing_mode)
          mode = normalized_pricing_mode(pricing_mode)
          return prices[key] unless mode

          prices[:"#{mode}_#{key}"] || prices[key]
        end

        def normalized_pricing_mode(value)
          return nil if value.nil?

          mode = value.to_s.strip
          return nil if mode.empty? || mode == "standard"

          mode
        end

        def missing_price_keys(effective)
          effective.filter_map { |key, value| key if value.nil? }
        end
      end
    end
  end
end
