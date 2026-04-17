# frozen_string_literal: true

module LlmCostTracker
  # Prices per 1M tokens in USD.
  # Updated: April 2026. Override via configuration.
  module Pricing
    PRICES = {
      # OpenAI
      "gpt-5.2"            => { input: 1.75,  cached_input: 0.175, output: 14.00 },
      "gpt-5.1"            => { input: 1.25,  cached_input: 0.125, output: 10.00 },
      "gpt-5"              => { input: 1.25,  cached_input: 0.125, output: 10.00 },
      "gpt-5-mini"         => { input: 0.25,  cached_input: 0.025, output: 2.00 },
      "gpt-5-nano"         => { input: 0.05,  cached_input: 0.005, output: 0.40 },
      "gpt-4.1"            => { input: 2.00,  cached_input: 0.50,  output: 8.00 },
      "gpt-4.1-mini"       => { input: 0.40,  cached_input: 0.10,  output: 1.60 },
      "gpt-4.1-nano"       => { input: 0.10,  cached_input: 0.025, output: 0.40 },
      "gpt-4o-2024-05-13"  => { input: 5.00,  output: 15.00 },
      "gpt-4o"             => { input: 2.50,  cached_input: 1.25,  output: 10.00 },
      "gpt-4o-mini"        => { input: 0.15,  cached_input: 0.075, output: 0.60 },
      "gpt-4-turbo"        => { input: 10.00, output: 30.00 },
      "gpt-4"              => { input: 30.00, output: 60.00 },
      "gpt-3.5-turbo"      => { input: 0.50,  output: 1.50 },
      "o1"                 => { input: 15.00, cached_input: 7.50,  output: 60.00 },
      "o1-mini"            => { input: 1.10,  cached_input: 0.55,  output: 4.40 },
      "o3"                 => { input: 2.00,  cached_input: 0.50,  output: 8.00 },
      "o3-mini"            => { input: 1.10,  cached_input: 0.55,  output: 4.40 },
      "o4-mini"            => { input: 1.10,  cached_input: 0.275, output: 4.40 },

      # Anthropic
      "claude-sonnet-4-6"  => { input: 3.00,  output: 15.00, cache_read_input: 0.30, cache_creation_input: 3.75 },
      "claude-opus-4-6"    => { input: 5.00,  output: 25.00, cache_read_input: 0.50, cache_creation_input: 6.25 },
      "claude-opus-4-1"    => { input: 15.00, output: 75.00, cache_read_input: 1.50, cache_creation_input: 18.75 },
      "claude-opus-4"      => { input: 15.00, output: 75.00, cache_read_input: 1.50, cache_creation_input: 18.75 },
      "claude-sonnet-4-5"  => { input: 3.00,  output: 15.00, cache_read_input: 0.30, cache_creation_input: 3.75 },
      "claude-sonnet-4"    => { input: 3.00,  output: 15.00, cache_read_input: 0.30, cache_creation_input: 3.75 },
      "claude-haiku-4-5"   => { input: 1.00,  output: 5.00,  cache_read_input: 0.10, cache_creation_input: 1.25 },
      "claude-3-7-sonnet"  => { input: 3.00,  output: 15.00, cache_read_input: 0.30, cache_creation_input: 3.75 },
      "claude-3-5-sonnet"  => { input: 3.00,  output: 15.00, cache_read_input: 0.30, cache_creation_input: 3.75 },
      "claude-3-5-haiku"   => { input: 0.80,  output: 4.00,  cache_read_input: 0.08, cache_creation_input: 1.00 },
      "claude-3-opus"      => { input: 15.00, output: 75.00, cache_read_input: 1.50, cache_creation_input: 18.75 },

      # Google Gemini
      "gemini-2.5-pro"     => { input: 1.25,  cached_input: 0.125, output: 10.00 },
      "gemini-2.5-flash"   => { input: 0.30,  cached_input: 0.03,  output: 2.50 },
      "gemini-2.5-flash-lite" => { input: 0.10, cached_input: 0.01, output: 0.40 },
      "gemini-2.0-flash" => { input: 0.10, cached_input: 0.025, output: 0.40 },
      "gemini-2.0-flash-lite" => { input: 0.075, output: 0.30 },
      "gemini-1.5-pro"     => { input: 1.25,  output: 5.00 },
      "gemini-1.5-flash"   => { input: 0.075, output: 0.30 }
    }.freeze

    class << self
      def cost_for(model:, input_tokens:, output_tokens:, cached_input_tokens: 0,
                   cache_read_input_tokens: 0, cache_creation_input_tokens: 0)
        prices = lookup(model)
        return nil unless prices

        cached_input_tokens = cached_input_tokens.to_i
        cache_read_input_tokens = cache_read_input_tokens.to_i
        cache_creation_input_tokens = cache_creation_input_tokens.to_i
        uncached_input_tokens = [input_tokens.to_i - cached_input_tokens, 0].max

        input_cost = (uncached_input_tokens.to_f / 1_000_000) * prices[:input]
        cached_input_cost = (cached_input_tokens.to_f / 1_000_000) *
                            (prices[:cached_input] || prices[:input])
        cache_read_input_cost = (cache_read_input_tokens.to_f / 1_000_000) *
                                (prices[:cache_read_input] || prices[:cached_input] || prices[:input])
        cache_creation_input_cost = (cache_creation_input_tokens.to_f / 1_000_000) *
                                    (prices[:cache_creation_input] || prices[:input])
        output_cost = (output_tokens.to_f / 1_000_000) * prices[:output]
        total_cost = input_cost + cached_input_cost + cache_read_input_cost +
                     cache_creation_input_cost + output_cost

        {
          input_cost: input_cost.round(8),
          cached_input_cost: cached_input_cost.round(8),
          cache_read_input_cost: cache_read_input_cost.round(8),
          cache_creation_input_cost: cache_creation_input_cost.round(8),
          output_cost: output_cost.round(8),
          total_cost: total_cost.round(8),
          currency: "USD"
        }
      end

      def lookup(model)
        overrides = LlmCostTracker.configuration.pricing_overrides
        overrides[model] || PRICES[model] || fuzzy_match(model)
      end

      def models
        PRICES.keys | LlmCostTracker.configuration.pricing_overrides.keys
      end

      private

      # Try to match model names like "gpt-4o-2024-08-06" to "gpt-4o"
      def fuzzy_match(model)
        return nil unless model

        PRICES.sort_by { |key, _value| -key.length }.each do |key, value|
          return value if model.start_with?(key)
        end

        nil
      end
    end
  end
end
