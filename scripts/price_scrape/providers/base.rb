# frozen_string_literal: true

require_relative "../../../lib/llm_cost_tracker/errors"
require_relative "../price_fields_validator"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Base
        Result = Data.define(:source_url, :scraped_at, :models, :deprecated_models, :service_charges)
        Error = LlmCostTracker::Error

        class << self
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
      end
    end
  end
end
