# frozen_string_literal: true

require "bigdecimal"

require_relative "../currency"
require_relative "../usage/catalog"
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
      DIMENSION_FIELDS = %i[kind direction modality cache_state unit].freeze
      DIMENSION_DEFAULTS = { cache_state: "none" }.freeze
      AMOUNT_DEFAULTS = {
        quantity: BigDecimal("0"), rate_amount: nil, rate_quantity: BigDecimal("1"), cost: nil
      }.freeze
      SOURCE_FIELDS = %i[pricing_basis price_key price_source].freeze
      private_constant :DIMENSION_FIELDS, :DIMENSION_DEFAULTS, :AMOUNT_DEFAULTS, :SOURCE_FIELDS

      def self.build(attributes)
        attributes = attributes.to_h
        new(**dimension_fields(attributes), **amount_fields(attributes), **source_fields(attributes))
      end

      def self.from_token_usage(token_usage)
        return [] unless token_usage

        from_quantities(token_usage.priced_quantities)
      end

      def self.from_quantities(quantities)
        quantities.filter_map do |key, quantity|
          next unless quantity.positive?

          dimension = Usage::Catalog.fetch(key)
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

      def self.dimension_fields(attributes)
        dimension = dimension_for(attributes).to_h
        DIMENSION_FIELDS.to_h do |field|
          [field, attributes[field]&.to_s || dimension[field] || DIMENSION_DEFAULTS[field]]
        end
      end

      def self.amount_fields(attributes)
        amounts = AMOUNT_DEFAULTS.to_h { |field, default| [field, decimal_or_nil(attributes[field]) || default] }
        amounts.merge(
          currency: (attributes[:currency] || LlmCostTracker::DEFAULT_CURRENCY).to_s.upcase,
          cost_status: (attributes[:cost_status] || CostStatus.for_cost(amounts[:cost])).to_s
        )
      end

      def self.source_fields(attributes)
        SOURCE_FIELDS.to_h { |field| [field, attributes[field]&.to_s] }.merge(
          price_source_version: attributes[:price_source_version],
          provider_field: attributes[:provider_field],
          provider_item_id: attributes[:provider_item_id],
          details: attributes[:details] || {}
        )
      end

      def self.dimension_for(attributes)
        dimension_key = attributes[:dimension_key] || attributes[:price_key]
        return nil unless dimension_key

        Usage::Catalog[dimension_key.to_s]
      end

      def self.decimal_or_nil(value)
        return nil if value.nil? || value == ""

        BigDecimal(value.to_s)
      end

      private_class_method :dimension_fields, :amount_fields, :source_fields, :dimension_for, :decimal_or_nil

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
        Usage::Catalog.find_by(
          kind: kind, direction: direction, modality: modality, cache_state: cache_state, unit: unit
        )
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
          cost_status: CostStatus.for_cost(applied_cost),
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
