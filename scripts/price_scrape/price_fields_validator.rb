# frozen_string_literal: true

require_relative "../../lib/llm_cost_tracker/pricing/registry"

module LlmCostTracker
  module Pricing::Scrape
    module PriceFieldsValidator
      class << self
        def call(models, minimum:, maximum:, error_class:, anchors: [])
          raise error_class, "expected at least #{minimum} models, parsed #{models.size}" if models.size < minimum

          missing_anchors = anchors - models.keys
          raise error_class, "anchor models missing from scrape: #{missing_anchors.join(', ')}" if missing_anchors.any?

          models.each do |model_id, fields|
            free = fields.values.all? { |value| value.is_a?(Float) && value.zero? }
            fields.each do |field, value|
              next if metadata_price_key?(field, value)
              next if value.is_a?(Float) && (value.positive? || free) && value < maximum

              raise error_class, "invalid price for #{model_id}.#{field}: #{value.inspect}"
            end
          end
        end

        private

        def metadata_price_key?(field, value)
          case field
          when Pricing::Registry::CONTEXT_THRESHOLD_KEY then value.is_a?(Integer) && value.positive?
          when Pricing::Registry::OFF_PEAK_WINDOWS_KEY then Pricing::OffPeak.windows(value, label: field) == value
          end
        rescue ArgumentError
          false
        end
      end
    end
  end
end
