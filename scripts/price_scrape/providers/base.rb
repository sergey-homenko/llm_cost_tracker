# frozen_string_literal: true

require_relative "../../../lib/llm_cost_tracker/errors"
require_relative "../price_fields_validator"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Base
        Result = Data.define(:source_url, :scraped_at, :models, :deprecated_models, :service_charges, :notes) do
          def initialize(notes: [], **) = super
        end
        Error = LlmCostTracker::Error
        STANDARD_FIELD = /\A(?<context>above_context_)?(?<field>input|output|cache_read_input)\z/

        class << self
          def followup_urls(_pages) = []

          def source_url(value = nil)
            @source_url = value if value
            @source_url
          end

          def min_models(value = nil)
            @min_models = value if value
            @min_models
          end

          def max_price(value = nil)
            @max_price = value if value
            @max_price
          end

          def anchors(*values)
            @anchors = values.flatten.freeze if values.any?
            @anchors || [].freeze
          end
        end

        def validate!(models)
          PriceFieldsValidator.call(
            models,
            minimum: self.class.min_models,
            maximum: self.class.max_price,
            anchors: self.class.anchors,
            error_class: self.class.const_get(:Error)
          )
        end

        private

        def tier_prices(fields, tier, factor)
          fields.each_with_object({}) do |(field, value), prices|
            match = STANDARD_FIELD.match(field)
            prices["#{match[:context]}#{tier}_#{match[:field]}"] = (value * factor).round(6) if match
          end
        end

        def documented_factor(page, pattern, name)
          factor = page.to_s[pattern, 1]
          raise Error, "#{self.class.name.split('::').last.downcase} #{name} rate not found in its docs" unless factor

          Float(factor)
        end
      end
    end
  end
end
