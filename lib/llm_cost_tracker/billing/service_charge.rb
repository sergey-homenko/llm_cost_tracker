# frozen_string_literal: true

require "bigdecimal"

require_relative "cost_status"
require_relative "components"

module LlmCostTracker
  module Billing
    ServiceCharge = Data.define(
      :charge_id,
      :component,
      :unit,
      :quantity,
      :rate_amount,
      :rate_quantity,
      :cost,
      :currency,
      :cost_status,
      :pricing_basis,
      :price_key,
      :price_source,
      :price_source_version,
      :source_key,
      :provider_item_id,
      :details
    )

    class ServiceCharge
      PROVIDER_USAGE_BASIS = "provider_usage"
      USD = "USD"
      STRING_ATTRIBUTES = %i[
        charge_id
        pricing_basis
        price_key
        price_source
        price_source_version
        source_key
        provider_item_id
      ].freeze

      def self.build(attributes)
        new(**normalized_attributes(attributes))
      end

      def self.build_many(values)
        Array(values).map { |value| value.is_a?(self) ? value : build(value) }
      end

      def self.status_for(cost)
        return CostStatus::UNKNOWN if cost.nil?

        cost.zero? ? CostStatus::FREE : CostStatus::COMPLETE
      end

      def self.decimal_or_nil(value)
        return nil if value.nil? || value == ""

        BigDecimal(value.to_s)
      end

      def self.decimal_or_zero(value)
        decimal_or_nil(value) || BigDecimal("0")
      end

      def self.normalized_attributes(attributes)
        attributes = attributes.to_h.transform_keys(&:to_sym)
        component = attributes.fetch(:component).to_sym
        definition = component_definition(component)
        cost = decimal_or_nil(attributes[:cost])

        {
          component: component.to_s,
          unit: (attributes[:unit] || definition.unit).to_s,
          quantity: decimal_or_zero(attributes[:quantity]),
          rate_amount: decimal_or_nil(attributes[:rate_amount]),
          rate_quantity: decimal_or_nil(attributes[:rate_quantity]) || BigDecimal("1"),
          cost: cost,
          currency: (attributes[:currency] || USD).to_s,
          cost_status: cost_status_for(attributes, cost),
          details: attributes[:details].is_a?(Hash) ? attributes[:details] : {}
        }.merge(string_attributes_for(attributes))
      end

      def self.component_definition(component)
        Components::BY_KEY.fetch(component) do
          raise Error, "Unknown billing component: #{component.inspect}"
        end
      end

      def self.cost_status_for(attributes, cost)
        status = attributes[:cost_status]&.to_s || status_for(cost)
        unless CostStatus::STATUSES.include?(status) && status != CostStatus::PARTIAL
          raise Error, "Invalid service charge cost_status: #{status.inspect}"
        end

        status
      end

      def self.string_attributes_for(attributes)
        STRING_ATTRIBUTES.to_h { |key| [key, attributes[key]&.to_s] }
      end

      private_class_method :component_definition, :cost_status_for, :decimal_or_nil, :decimal_or_zero,
                           :normalized_attributes, :status_for, :string_attributes_for

      def priced?
        case cost_status
        when CostStatus::COMPLETE, CostStatus::FREE
          true
        else
          false
        end
      end

      def unpriced?
        cost_status == CostStatus::UNKNOWN
      end

      def billable?
        quantity.positive?
      end

      def cost_value
        cost || BigDecimal("0")
      end

      def to_h
        super.transform_values do |value|
          value.is_a?(BigDecimal) ? value.to_s("F") : value
        end
      end
    end
  end
end
