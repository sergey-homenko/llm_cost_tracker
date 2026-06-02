# frozen_string_literal: true

require_relative "../usage/catalog"
require_relative "mode"

module LlmCostTracker
  module Pricing
    module PriceKey
      ABOVE_CONTEXT_PREFIX = "above_context_"

      class << self
        def build(dimension_key, mode: nil, above_context: false)
          key = mode ? "#{mode}_#{dimension_key}" : dimension_key.to_s
          above_context ? "#{ABOVE_CONTEXT_PREFIX}#{key}" : key
        end

        def dimension_for(key)
          key = key.to_s
          dimension_key = strip_mode_prefix(key.delete_prefix(ABOVE_CONTEXT_PREFIX))
          dimension = Usage::Catalog[dimension_key]
          return nil unless dimension
          return key if key == dimension_key

          dimension.token_key ? key : nil
        end

        def parse_dimension_key(key)
          name = key.to_s
          Usage::Catalog.all.each do |dimension|
            return [dimension, nil] if dimension.key == name

            suffix = "_#{dimension.key}"
            next unless name.end_with?(suffix)

            tier = name.delete_suffix(suffix)
            return [dimension, tier] unless tier.empty?
          end
          nil
        end

        private

        def strip_mode_prefix(key)
          loop do
            modifier = Mode::KNOWN_MODIFIERS.find { |m| key.start_with?("#{m}_") }
            break unless modifier

            key = key.delete_prefix("#{modifier}_")
          end
          key
        end
      end
    end
  end
end
