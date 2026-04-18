# frozen_string_literal: true

module LlmCostTracker
  # Calculates costs from price entries expressed in USD per 1M tokens.
  module Pricing
    PRICES = PriceRegistry.builtin_prices
    PRICES_MUTEX = Mutex.new
    SORTED_PRICE_KEYS_MUTEX = Mutex.new

    private_constant :PRICES_MUTEX
    private_constant :SORTED_PRICE_KEYS_MUTEX

    class << self
      # Estimate model cost from token counts.
      #
      # @param model [String] Provider model identifier.
      # @param input_tokens [Integer] Input token count, including cached tokens if reported that way.
      # @param output_tokens [Integer] Output token count.
      # @param cached_input_tokens [Integer] OpenAI-style cached input tokens.
      # @param cache_read_input_tokens [Integer] Anthropic-style cache read tokens.
      # @param cache_creation_input_tokens [Integer] Anthropic-style cache creation tokens.
      # @return [LlmCostTracker::Cost, nil] nil when no price is configured for the model.
      def cost_for(model:, input_tokens:, output_tokens:, cached_input_tokens: 0,
                   cache_read_input_tokens: 0, cache_creation_input_tokens: 0)
        prices = lookup(model)
        return nil unless prices

        token_counts = normalized_token_counts(input_tokens, output_tokens, cached_input_tokens,
                                               cache_read_input_tokens, cache_creation_input_tokens)
        costs = calculate_costs(token_counts, prices)

        Cost.new(
          input_cost: costs[:input].round(8),
          cached_input_cost: costs[:cached_input].round(8),
          cache_read_input_cost: costs[:cache_read_input].round(8),
          cache_creation_input_cost: costs[:cache_creation_input].round(8),
          output_cost: costs[:output].round(8),
          total_cost: costs.values.sum.round(8),
          currency: "USD"
        )
      end

      def lookup(model)
        table = prices
        model_name = model.to_s
        normalized_model = normalize_model_name(model_name)

        table[model_name] || table[normalized_model] || fuzzy_match(model_name, normalized_model, table)
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

        return @prices if @prices_cache_key == cache_key

        PRICES_MUTEX.synchronize do
          return @prices if @prices_cache_key == cache_key

          @prices_cache_key = cache_key
          @prices = PRICES.merge(file_prices).merge(overrides).freeze
        end
      end

      private

      def normalized_token_counts(input_tokens, output_tokens, cached_input_tokens,
                                  cache_read_input_tokens, cache_creation_input_tokens)
        cached_input_tokens = cached_input_tokens.to_i

        {
          input: [input_tokens.to_i - cached_input_tokens, 0].max,
          cached_input: cached_input_tokens,
          cache_read_input: cache_read_input_tokens.to_i,
          cache_creation_input: cache_creation_input_tokens.to_i,
          output: output_tokens.to_i
        }
      end

      def calculate_costs(token_counts, prices)
        {
          input: token_cost(token_counts[:input], prices[:input]),
          cached_input: token_cost(token_counts[:cached_input], prices[:cached_input] || prices[:input]),
          cache_read_input: token_cost(
            token_counts[:cache_read_input],
            prices[:cache_read_input] || prices[:cached_input] || prices[:input]
          ),
          cache_creation_input: token_cost(
            token_counts[:cache_creation_input],
            prices[:cache_creation_input] || prices[:input]
          ),
          output: token_cost(token_counts[:output], prices[:output])
        }
      end

      def token_cost(tokens, per_million_price)
        (tokens.to_f / 1_000_000) * per_million_price
      end

      def normalize_model_name(model)
        model.to_s.split("/").last
      end

      # Try to match model names like "gpt-4o-2024-08-06" to "gpt-4o".
      def fuzzy_match(model, normalized_model, table)
        sorted_price_keys(table).each do |key|
          return table[key] if model.start_with?(key) || normalized_model.start_with?(key)
        end

        nil
      end

      def sorted_price_keys(table)
        return @sorted_price_keys if @sorted_price_keys_table.equal?(table)

        SORTED_PRICE_KEYS_MUTEX.synchronize do
          return @sorted_price_keys if @sorted_price_keys_table.equal?(table)

          @sorted_price_keys_table = table
          @sorted_price_keys = table.keys.sort_by { |key| -key.length }
        end
      end
    end
  end
end
