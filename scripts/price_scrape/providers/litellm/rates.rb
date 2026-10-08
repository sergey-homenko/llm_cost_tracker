# frozen_string_literal: true

require_relative "../base"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Litellm < Base
        class Rates
          attr_reader :fields, :thresholds

          def initialize(prices, provider = nil)
            @prices = prices
            @provider = provider
            @thresholds = []
            @fields = prices.each_with_object({}) { |(name, value), fields| add(fields, name, value) }
          end

          private

          def add(fields, name, value)
            match = FIELD.match(name)
            return add_token_rate(fields, match, value) if match

            dimension, price = unit_price(name, value)
            fields[dimension] = price if dimension
          end

          def add_token_rate(fields, match, value)
            return unless value.is_a?(Numeric) && value.positive?

            field = [TIERS[match[:tier]], TOKEN_FIELDS.fetch(match[:field])].compact.join("_")
            if match[:thousands]
              field = "above_context_#{field}"
              @thresholds << (Integer(match[:thousands]) * 1000)
            end
            fields[field] ||= (value * 1_000_000).round(6)
          end

          def unit_price(name, value)
            dimension, scale, mode = UNIT_FIELDS[name]
            value = value["search_context_size_medium"] if value.is_a?(Hash)
            return unless dimension && value.is_a?(Numeric) && value.positive? && priced_per_unit?(mode)

            dimension = "grounding_request" if dimension == "web_search_request" && @provider == "gemini"
            [dimension, (value * scale).round(6)]
          end

          def priced_per_unit?(mode)
            mode.nil? || (mode == @prices["mode"] && !@prices["input_cost_per_token"].to_f.positive?)
          end
        end
      end
    end
  end
end
