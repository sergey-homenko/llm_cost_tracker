# frozen_string_literal: true

require "active_support/core_ext/hash/keys"

require_relative "../token_usage"

module LlmCostTracker
  module Pricing
    Cost = Data.define(
      *TokenUsage::PRICED_COMPONENTS.map(&:cost_key),
      :total_cost,
      :currency
    ) do
      def self.from_hash(attributes)
        attributes = attributes.to_h.symbolize_keys
        values = TokenUsage::PRICED_COMPONENTS.to_h do |component|
          [component.cost_key, attributes[component.cost_key]]
        end
        new(
          **values,
          total_cost: attributes[:total_cost],
          currency: attributes[:currency]
        )
      end

      def stored_attributes
        to_h.slice(*STORED_KEYS)
      end

      def to_h
        super.compact
      end
    end

    Cost::BASE_STORED_KEYS = (TokenUsage::BASE_PRICED_COMPONENTS.map(&:cost_key) + [:total_cost]).freeze
    Cost::OPTIONAL_STORED_KEYS = TokenUsage::OPTIONAL_PRICED_COMPONENTS.map(&:cost_key).freeze
    Cost::STORED_KEYS = (Cost::BASE_STORED_KEYS + Cost::OPTIONAL_STORED_KEYS).freeze

    Cost::BASE_DASHBOARD_SUM_KEYS = TokenUsage::BASE_PRICED_COMPONENTS.map(&:cost_key).freeze
    Cost::OPTIONAL_DASHBOARD_SUM_KEYS = TokenUsage::OPTIONAL_PRICED_COMPONENTS.map(&:cost_key).freeze
    Cost::DASHBOARD_SUM_KEYS = (Cost::BASE_DASHBOARD_SUM_KEYS + Cost::OPTIONAL_DASHBOARD_SUM_KEYS).freeze
  end
end
