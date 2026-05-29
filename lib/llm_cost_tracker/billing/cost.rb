# frozen_string_literal: true

require "bigdecimal"

module LlmCostTracker
  module Billing
    Cost = Data.define(:components, :total, :currency) do
      def self.from_h(attributes)
        total = attributes[:total_cost]
        components = attributes.except(:total_cost, :currency).transform_values { |value| BigDecimal(value.to_s) }
        new(components: components.freeze, total: total && BigDecimal(total.to_s), currency: attributes[:currency])
      end

      def to_h
        components.merge(total_cost: total, currency: currency)
      end
    end
  end
end
