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
      USD = "USD"
      OPTIONAL_ATTRIBUTES = %i[
        pricing_basis
        price_key
        price_source
        price_source_version
        provider_field
        provider_item_id
      ].freeze
      SYMBOL_ATTRIBUTES = %i[
        kind
        direction
        modality
        cache_state
        unit
        pricing_basis
        price_source
      ].freeze

      def self.build(attributes)
        attributes = attributes.to_h
        component = component_for(attributes)
        normalized = {
          kind: symbol_or_nil(attributes[:kind]) || component&.kind,
          direction: symbol_or_nil(attributes[:direction]) || component&.direction,
          modality: symbol_or_nil(attributes[:modality]) || component&.modality,
          cache_state: symbol_or_nil(attributes[:cache_state]) || component&.cache_state,
          quantity: decimal_or_zero(attributes[:quantity]),
          unit: symbol_or_nil(attributes[:unit]) || component&.unit,
          rate_amount: decimal_or_nil(attributes[:rate_amount]),
          rate_quantity: decimal_or_nil(attributes[:rate_quantity]) || BigDecimal("1"),
          cost: decimal_or_nil(attributes[:cost]),
          currency: attributes[:currency] || USD,
          cost_status: cost_status_for(attributes),
          details: attributes[:details] || {}
        }.merge(optional_attributes_for(attributes))

        new(**normalized)
      end

      def self.from_token_usage(token_usage)
        return [] unless token_usage

        Components::TOKEN_PRICED.filter_map do |component|
          quantity = token_usage.public_send(component.token_key)
          next unless quantity.positive?

          new(
            kind: component.kind,
            direction: component.direction,
            modality: component.modality,
            cache_state: component.cache_state,
            quantity: BigDecimal(quantity.to_s),
            unit: component.unit,
            rate_amount: nil,
            rate_quantity: BigDecimal("1"),
            cost: nil,
            currency: USD,
            cost_status: CostStatus::UNKNOWN,
            pricing_basis: nil,
            price_key: nil,
            price_source: nil,
            price_source_version: nil,
            provider_field: nil,
            provider_item_id: nil,
            details: {}
          )
        end
      end

      def self.from_service_charge(charge)
        component = Components::BY_KEY.fetch(charge.component)
        new(
          kind: component.kind,
          direction: component.direction,
          modality: component.modality,
          cache_state: :none,
          quantity: charge.quantity,
          unit: charge.unit,
          rate_amount: charge.rate_amount,
          rate_quantity: charge.rate_quantity,
          cost: charge.cost,
          currency: charge.currency,
          cost_status: charge.cost_status,
          pricing_basis: charge.pricing_basis,
          price_key: charge.price_key,
          price_source: charge.price_source,
          price_source_version: charge.price_source_version,
          provider_field: charge.source_key,
          provider_item_id: charge.provider_item_id,
          details: charge.details || {}
        )
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

        Components::BY_KEY[component_key.to_sym]
      end

      def self.symbol_or_nil(value)
        return nil if value.nil?

        value.is_a?(Symbol) ? value : value.to_s.to_sym
      end

      def self.decimal_or_nil(value)
        return nil if value.nil? || value == ""

        BigDecimal(value.to_s)
      end

      def self.decimal_or_zero(value)
        decimal_or_nil(value) || BigDecimal("0")
      end

      def self.optional_attributes_for(attributes)
        OPTIONAL_ATTRIBUTES.to_h do |key|
          value = attributes[key]
          value = value.to_sym if value.is_a?(String) && SYMBOL_ATTRIBUTES.include?(key)
          [key, value]
        end
      end

      private_class_method :cost_status_for, :component_for, :symbol_or_nil, :decimal_or_nil, :decimal_or_zero,
                           :optional_attributes_for

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
        unit == :token
      end

      def cost_value
        cost || BigDecimal("0")
      end

      def apply_rate(rate)
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
