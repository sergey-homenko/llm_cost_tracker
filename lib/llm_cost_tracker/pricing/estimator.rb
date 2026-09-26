# frozen_string_literal: true

require "bigdecimal"

module LlmCostTracker
  module Pricing
    module Estimator
      CHARS_PER_TOKEN = 4

      def self.call(provider:, model:, request:)
        chars = char_count(request)
        return BigDecimal("0") if chars.zero?

        estimated_tokens = (chars.to_f / CHARS_PER_TOKEN).ceil
        cost_data = Pricing.cost_for(
          provider: provider,
          model: model,
          tokens: { input_tokens: estimated_tokens }
        )
        cost_data&.total
      end

      def self.char_count(value)
        case value
        when String then value.match?(/\Adata:[^,]*;base64,/) ? 0 : value.length
        when Hash
          return 0 if value["type"].to_s == "base64"

          value.except("input_audio", "inline_data", "inlineData").values.sum { |nested| char_count(nested) }
        when Array then value.sum { |nested| char_count(nested) }
        else 0
        end
      end
    end
  end
end
