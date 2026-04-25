# frozen_string_literal: true

require "monitor"

module LlmCostTracker
  module Pricing
    PRICES = PriceRegistry.builtin_prices
    MUTEX = Monitor.new

    class << self
      def cost_for(provider:, model:, input_tokens:, output_tokens:, cache_read_input_tokens: 0,
                   cache_write_input_tokens: 0, pricing_mode: nil)
        prices = lookup(provider: provider, model: model)
        return nil unless prices

        usage = UsageBreakdown.build(
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          cache_read_input_tokens: cache_read_input_tokens,
          cache_write_input_tokens: cache_write_input_tokens
        )
        costs = calculate_costs(usage, prices, pricing_mode: pricing_mode)

        Cost.new(
          input_cost: costs[:input].round(8),
          cache_read_input_cost: costs[:cache_read_input].round(8),
          cache_write_input_cost: costs[:cache_write_input].round(8),
          output_cost: costs[:output].round(8),
          total_cost: costs.values.sum.round(8),
          currency: "USD"
        )
      end

      def lookup(provider:, model:)
        table = prices
        provider_name = provider.to_s
        model_name = model.to_s
        provider_model = provider_name.empty? ? model_name : "#{provider_name}/#{model_name}"
        normalized_model = normalize_model_name(model_name)

        table[provider_model] ||
          table[model_name] ||
          table[normalized_model] ||
          fuzzy_match(provider_model, normalized_model, table)
      end

      def models
        prices.keys
      end

      def metadata
        PriceRegistry.metadata
      end

      def prices
        file_prices = PriceRegistry.file_prices(LlmCostTracker.configuration.prices_file)
        overrides = PriceRegistry.normalize_price_table(LlmCostTracker.configuration.pricing_overrides)
        cache_key = [file_prices.object_id, LlmCostTracker.configuration.pricing_overrides.hash]

        cached = @prices_cache
        return cached[:value] if cached && cached[:key] == cache_key

        MUTEX.synchronize do
          cached = @prices_cache
          return cached[:value] if cached && cached[:key] == cache_key

          value = PRICES.merge(file_prices).merge(overrides).freeze
          @prices_cache = { key: cache_key, value: value }.freeze
          value
        end
      end

      private

      def calculate_costs(usage, prices, pricing_mode:)
        {
          input: token_cost(usage.input_tokens, price_for(prices, :input, pricing_mode)),
          cache_read_input: token_cost(
            usage.cache_read_input_tokens,
            price_for(prices, :cache_read_input, pricing_mode) || price_for(prices, :input, pricing_mode)
          ),
          cache_write_input: token_cost(
            usage.cache_write_input_tokens,
            price_for(prices, :cache_write_input, pricing_mode) || price_for(prices, :input, pricing_mode)
          ),
          output: token_cost(usage.output_tokens, price_for(prices, :output, pricing_mode))
        }
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

      def token_cost(tokens, per_million_price)
        return 0.0 if tokens.to_i.zero?

        (tokens.to_f / 1_000_000) * per_million_price
      end

      def normalize_model_name(model)
        model.to_s.split("/").last
      end

      def fuzzy_match(model, normalized_model, table)
        sorted_price_keys(table).each do |key|
          return table[key] if snapshot_variant?(model, key) || snapshot_variant?(normalized_model, key)
        end

        nil
      end

      def snapshot_variant?(model, key)
        suffix = model.delete_prefix("#{key}-")
        return false if suffix == model

        suffix.match?(/\A(?:\d{4}-\d{2}-\d{2}|\d{8})\z/)
      end

      def sorted_price_keys(table)
        cached = @sorted_price_keys_cache
        return cached[:keys] if cached && cached[:table].equal?(table)

        MUTEX.synchronize do
          cached = @sorted_price_keys_cache
          return cached[:keys] if cached && cached[:table].equal?(table)

          keys = table.keys.sort_by { |key| -key.length }
          @sorted_price_keys_cache = { table: table, keys: keys }.freeze
          keys
        end
      end
    end
  end
end
