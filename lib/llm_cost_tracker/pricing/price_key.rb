# frozen_string_literal: true

require_relative "../usage/catalog"
require_relative "mode"

module LlmCostTracker
  module Pricing
    module PriceKey
      ABOVE_CONTEXT_PREFIX = "above_context_"
      SCHEDULED_SUFFIX = /_from_(\d{4}-\d{2}-\d{2})\z/

      class << self
        def build(dimension_key, mode: nil, above_context: false)
          key = mode ? "#{mode}_#{dimension_key}" : dimension_key.to_s
          above_context ? "#{ABOVE_CONTEXT_PREFIX}#{key}" : key
        end

        def price_key_for(key)
          key = key.to_s
          base = key.sub(SCHEDULED_SUFFIX, "")
          dimension_key = strip_mode_prefix(base.delete_prefix(ABOVE_CONTEXT_PREFIX))
          dimension = Usage::Catalog[dimension_key]
          return nil unless dimension
          return nil if dimension.token_key.nil? && base.start_with?(ABOVE_CONTEXT_PREFIX)

          key
        end

        def parse_dimension_key(key)
          name = key.to_s
          exact = Usage::Catalog.all.find { |dimension| dimension.key == name }
          return [exact, nil] if exact

          Usage::Catalog.all.sort_by { |dimension| -dimension.key.length }.each do |dimension|
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
