# frozen_string_literal: true

require "bigdecimal"

module LlmCostTracker
  module Billing
    Cost = Data.define(:components, :total, :currency) do
      def self.from_h(attributes)
        components = attributes.key?(:components) ? attributes[:components] : attributes.except(:total_cost, :currency)
        total = attributes.fetch(:total) { attributes[:total_cost] }
        new(
          components: components.transform_values { |value| BigDecimal(value.to_s) }.freeze,
          total: total && BigDecimal(total.to_s),
          currency: attributes[:currency]
        )
      end

      def to_h
        {
          components: components.transform_values { |value| value.to_s("F") },
          total: total&.to_s("F"),
          currency: currency
        }
      end
    end
  end
end
