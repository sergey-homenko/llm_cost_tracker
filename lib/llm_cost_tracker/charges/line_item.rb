# frozen_string_literal: true

require "bigdecimal"

require_relative "../currency"
require_relative "../usage/dimension"
require_relative "cost_status"

module LlmCostTracker
  module Charges
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
        dimension = dimension_for(attributes)
        new(
          kind: attributes[:kind]&.to_s || dimension&.kind,
          direction: attributes[:direction]&.to_s || dimension&.direction,
          modality: attributes[:modality]&.to_s || dimension&.modality,
          cache_state: attributes[:cache_state]&.to_s || dimension&.cache_state || "none",
          quantity: decimal_or_nil(attributes[:quantity]) || BigDecimal("0"),
          unit: attributes[:unit]&.to_s || dimension&.unit,
          rate_amount: decimal_or_nil(attributes[:rate_amount]),
          rate_quantity: decimal_or_nil(attributes[:rate_quantity]) || BigDecimal("1"),
          cost: decimal_or_nil(attributes[:cost]),
          currency: canonical_currency(attributes[:currency]),
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

          dimension = Usage::Dimension::BY_KEY.fetch(key)
          build(
            kind: dimension.kind,
            direction: dimension.direction,
            modality: dimension.modality,
            cache_state: dimension.cache_state,
            quantity: quantity,
            unit: dimension.unit
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

      def self.dimension_for(attributes)
        dimension_key = attributes[:dimension_key] || attributes[:price_key]
        return nil unless dimension_key

        Usage::Dimension::BY_KEY[dimension_key.to_s]
      end

      def self.decimal_or_nil(value)
        return nil if value.nil? || value == ""

        BigDecimal(value.to_s)
      end

      def self.canonical_currency(value)
        (value || LlmCostTracker::DEFAULT_CURRENCY).to_s.upcase
      end

      private_class_method :cost_status_for, :dimension_for, :decimal_or_nil, :canonical_currency

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

      def dimension
        Usage::Dimension::BY_KEY[price_key] ||
          Usage::Dimension.token_priced_for(kind: kind, direction: direction, cache_state: cache_state)
      end

      def cost_value
        cost || BigDecimal("0")
      end

      def with_rate(rate)
        applied_cost = (quantity / rate.quantity) * rate.amount
        with(
          rate_amount: rate.amount,
          rate_quantity: rate.quantity,
          cost: applied_cost,
          currency: rate.currency.upcase,
          cost_status: applied_cost.zero? ? CostStatus::FREE : CostStatus::COMPLETE,
          price_key: rate.source_key,
          price_source: rate.source,
          price_source_version: rate.source_version
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
