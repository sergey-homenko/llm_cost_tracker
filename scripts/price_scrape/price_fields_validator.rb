# frozen_string_literal: true

module LlmCostTracker
  module Pricing::Scrape
    module PriceFieldsValidator
      class << self
        def call(models, minimum:, maximum:, error_class:)
          raise error_class, "expected at least #{minimum} models, parsed #{models.size}" if models.size < minimum

          models.each do |model_id, fields|
            fields.each do |field, value|
              next if metadata_price_key?(field, value)
              next if value.is_a?(Float) && value.positive? && value < maximum

              raise error_class, "invalid price for #{model_id}.#{field}: #{value.inspect}"
            end
          end
        end

        private

        def metadata_price_key?(field, value)
          field == "_context_price_threshold_tokens" && value.is_a?(Integer) && value.positive?
        end
      end
    end
  end
end
