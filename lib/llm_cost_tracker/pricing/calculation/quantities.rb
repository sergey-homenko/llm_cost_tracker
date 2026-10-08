# frozen_string_literal: true

module LlmCostTracker
  module Pricing
    class Calculation
      class Quantities
        UNIT_BILLED_KINDS = %w[transcription_minute text_to_speech_character ocr_page rerank_search_unit].freeze

        def initialize(token_usage, line_items, prices)
          @token_usage = token_usage
          @line_items = line_items
          @price_keys = prices.keys
        end

        def to_h
          @line_items.each_with_object(token_counts) do |line_item, quantities|
            dimension = line_item.dimension
            next unless dimension&.parent

            quantity = [line_item.quantity.to_i, quantities.fetch(dimension.parent)].min
            quantities[dimension.parent] -= quantity
            quantities[dimension.key] = quantities.fetch(dimension.key, 0) + quantity
          end
        end

        private

        def token_counts
          counts = @token_usage.priced_quantities
          billed_by_unit? ? counts.transform_values { 0 } : counts
        end

        def billed_by_unit?
          !@price_keys.intersect?(Registry::PRICE_KEYS) &&
            (@price_keys & UNIT_BILLED_KINDS).intersect?(@line_items.map(&:kind))
        end
      end
    end
  end
end
