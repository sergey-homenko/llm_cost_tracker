# frozen_string_literal: true

require_relative "components"

module LlmCostTracker
  module Billing
    module CostStatus
      COMPLETE = "complete"
      FREE = "free"
      PARTIAL = "partial"
      UNKNOWN = "unknown"
      INCOMPLETE = [UNKNOWN, PARTIAL].freeze

      # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      def self.call(token_usage:, usage_source:, token_cost:, service_line_items:, total_cost:,
                    token_pricing_partial: false)
        return UNKNOWN if usage_source == :unknown

        token_billable = token_usage.priced_quantities.any? { |_key, quantity| quantity.positive? }
        service_billable = false
        service_priced = false
        service_unpriced = false
        service_line_items.each do |line_item|
          next unless line_item.billable?

          service_billable = true
          service_priced ||= line_item.priced?
          service_unpriced ||= line_item.unpriced?
          break if service_priced && service_unpriced
        end

        priced = (token_billable && !token_cost.nil?) || service_priced || (!token_billable && !service_billable)
        unpriced = (token_billable && (token_cost.nil? || token_pricing_partial)) || service_unpriced
        return UNKNOWN if unpriced && !priced
        return PARTIAL if unpriced

        total_cost.nil? || total_cost.zero? ? FREE : COMPLETE
      end
      # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    end
  end
end
