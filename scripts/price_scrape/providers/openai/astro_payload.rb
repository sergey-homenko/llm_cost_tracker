# frozen_string_literal: true

require_relative "../base"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Openai < Base
        module AstroPayload
          private

          def unwrap(value)
            return unwrap(value[1]) if value.is_a?(Array) && value.size == 2 && value[0].is_a?(Integer)

            value
          end
        end
      end
    end
  end
end
