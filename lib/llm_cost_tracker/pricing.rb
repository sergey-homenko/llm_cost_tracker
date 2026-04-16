# frozen_string_literal: true

module LlmCostTracker
  # Prices per 1M tokens in USD.
  # Updated: April 2026. Override via configuration.
  module Pricing
    PRICES = {
      # OpenAI
      "gpt-4o"             => { input: 2.50,  output: 10.00 },
      "gpt-4o-mini"        => { input: 0.15,  output: 0.60 },
      "gpt-4-turbo"        => { input: 10.00, output: 30.00 },
      "gpt-4"              => { input: 30.00, output: 60.00 },
      "gpt-3.5-turbo"      => { input: 0.50,  output: 1.50 },
      "o1"                 => { input: 15.00, output: 60.00 },
      "o1-mini"            => { input: 3.00,  output: 12.00 },
      "o3-mini"            => { input: 1.10,  output: 4.40 },

      # Anthropic
      "claude-sonnet-4-6"  => { input: 3.00,  output: 15.00 },
      "claude-opus-4-6"    => { input: 15.00, output: 75.00 },
      "claude-haiku-4-5"   => { input: 0.80,  output: 4.00 },
      "claude-3-5-sonnet-20241022" => { input: 3.00,  output: 15.00 },
      "claude-3-5-haiku-20241022"  => { input: 0.80,  output: 4.00 },
      "claude-3-opus-20240229"     => { input: 15.00, output: 75.00 },

      # Google Gemini
      "gemini-2.5-pro"     => { input: 1.25,  output: 10.00 },
      "gemini-2.5-flash"   => { input: 0.15,  output: 0.60 },
      "gemini-2.0-flash"   => { input: 0.10,  output: 0.40 },
      "gemini-1.5-pro"     => { input: 1.25,  output: 5.00 },
      "gemini-1.5-flash"   => { input: 0.075, output: 0.30 },
    }.freeze

    class << self
      def cost_for(model:, input_tokens:, output_tokens:)
        prices = lookup(model)
        return nil unless prices

        input_cost  = (input_tokens.to_f / 1_000_000) * prices[:input]
        output_cost = (output_tokens.to_f / 1_000_000) * prices[:output]

        {
          input_cost: input_cost.round(8),
          output_cost: output_cost.round(8),
          total_cost: (input_cost + output_cost).round(8),
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

        PRICES.each do |key, value|
          return value if model.start_with?(key)
        end

        nil
      end
    end
  end
end
