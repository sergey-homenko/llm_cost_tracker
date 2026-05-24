# frozen_string_literal: true

require "bigdecimal"

require_relative "components"
require_relative "cost_status"

module LlmCostTracker
  module Billing
    LineItem = Data.define(
      :kind,
      :direction,
      :modality,
      :cache_state,
      :quantity,
      :unit,
      :rate_amount,
      :rate_quantity,
      :cost,
      :currency,
      :cost_status,
      :pricing_basis,
      :price_key,
      :price_source,
      :price_source_version,
      :provider_field,
      :provider_item_id,
      :details
    )

    class LineItem
      def self.build(attributes)
        attributes = attributes.to_h
        component = component_for(attributes)
        new(
          kind: attributes[:kind]&.to_s || component&.kind,
          direction: attributes[:direction]&.to_s || component&.direction,
          modality: attributes[:modality]&.to_s || component&.modality,
          cache_state: attributes[:cache_state]&.to_s || component&.cache_state,
          quantity: decimal_or_nil(attributes[:quantity]) || BigDecimal("0"),
          unit: attributes[:unit]&.to_s || component&.unit,
          rate_amount: decimal_or_nil(attributes[:rate_amount]),
          rate_quantity: decimal_or_nil(attributes[:rate_quantity]) || BigDecimal("1"),
          cost: decimal_or_nil(attributes[:cost]),
          currency: attributes[:currency] || DEFAULT_CURRENCY,
          cost_status: cost_status_for(attributes),
          pricing_basis: attributes[:pricing_basis]&.to_s,
          price_key: attributes[:price_key]&.to_s,
          price_source: attributes[:price_source]&.to_s,
          price_source_version: attributes[:price_source_version],
          provider_field: attributes[:provider_field],
          provider_item_id: attributes[:provider_item_id],
          details: attributes[:details] || {}
        )
      end

      def self.from_token_usage(token_usage)
        return [] unless token_usage

        token_usage.priced_quantities.filter_map do |key, quantity|
          next unless quantity.positive?

          component = Components::BY_KEY.fetch(key)
          build(
            kind: component.kind,
            direction: component.direction,
            modality: component.modality,
            cache_state: component.cache_state,
            quantity: quantity,
            unit: component.unit
          )
        end
      end

      def self.cost_status_for(attributes)
        explicit = attributes[:cost_status]
        return explicit.to_s if explicit

        cost = decimal_or_nil(attributes[:cost])
        return CostStatus::UNKNOWN if cost.nil?

        cost.zero? ? CostStatus::FREE : CostStatus::COMPLETE
      end

      def self.component_for(attributes)
        component_key = attributes[:component_key] || attributes[:price_key]
        return nil unless component_key

        Components::BY_KEY[component_key.to_s]
      end

      def self.decimal_or_nil(value)
        return nil if value.nil? || value == ""

        BigDecimal(value.to_s)
      end

      private_class_method :cost_status_for, :component_for, :decimal_or_nil

      def billable?
        quantity.positive?
      end

      def priced?
        [CostStatus::COMPLETE, CostStatus::FREE].include?(cost_status)
      end

      def unpriced?
        cost_status == CostStatus::UNKNOWN
      end

      def token?
        unit == "token"
      end

      def cost_value
        cost || BigDecimal("0")
      end

      def with_rate(rate)
        rate_amount = rate.fetch(:amount)
        rate_quantity = rate.fetch(:quantity)
        applied_cost = (quantity / rate_quantity) * rate_amount
        with(
          rate_amount: rate_amount,
          rate_quantity: rate_quantity,
          cost: applied_cost,
          currency: rate.fetch(:currency),
          cost_status: applied_cost.zero? ? CostStatus::FREE : CostStatus::COMPLETE,
          price_key: rate.fetch(:source_key),
          price_source: rate.fetch(:source),
          price_source_version: rate.fetch(:source_version)
        )
      end

      def to_h
        super.transform_values do |value|
          value.is_a?(BigDecimal) ? value.to_s("F") : value
        end
      end
    end
  end
end
