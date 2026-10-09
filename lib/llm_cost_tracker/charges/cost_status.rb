# frozen_string_literal: true

require_relative "../usage/source"

module LlmCostTracker
  module Charges
    module CostStatus
      COMPLETE = "complete"
      FREE = "free"
      PARTIAL = "partial"
      UNKNOWN = "unknown"
      INCOMPLETE = [UNKNOWN, PARTIAL].freeze

      TokenCharge = Data.define(:cost, :partial) do
        def priced? = !cost.nil?

        def unpriced? = cost.nil? || partial
      end
      private_constant :TokenCharge

      def self.unknown_pricing_sql(total_cost: "total_cost", cost_status: "cost_status")
        statuses = INCOMPLETE.map { |status| ActiveRecord::Base.lease_connection.quote(status) }.join(", ")
        "#{total_cost} IS NULL OR #{cost_status} IN (#{statuses})"
      end

      def self.call(token_usage:,
                    usage_source:,
                    token_cost:,
                    service_line_items:,
                    total_cost:,
                    token_pricing_partial: false)
        return UNKNOWN if usage_source == Usage::Source::UNKNOWN

        charges = billable_charges(token_usage, token_cost, token_pricing_partial, service_line_items)
        return for_cost(total_cost) if charges.none?(&:unpriced?)

        charges.any?(&:priced?) ? PARTIAL : UNKNOWN
      end

      def self.for_cost(cost)
        return UNKNOWN if cost.nil?

        cost.zero? ? FREE : COMPLETE
      end

      def self.billable_charges(token_usage, token_cost, token_pricing_partial, service_line_items)
        charges = service_line_items.select(&:billable?)
        return charges unless token_usage.total_tokens.to_i.positive? ||
                              token_usage.priced_quantities.any? { |_key, quantity| quantity.positive? }

        charges + [TokenCharge.new(cost: token_cost, partial: token_pricing_partial)]
      end
      private_class_method :billable_charges
    end
  end
end
