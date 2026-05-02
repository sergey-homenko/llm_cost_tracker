# frozen_string_literal: true

require_relative "components"

module LlmCostTracker
  module Billing
    module CostStatus
      COMPLETE = "complete"
      FREE = "free"
      PARTIAL = "partial"
      UNKNOWN = "unknown"
      SERVICE_CHARGE_STATUSES = [COMPLETE, FREE, UNKNOWN].freeze

      class << self
        # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        def call(token_usage:, usage_source:, token_cost:, service_charges:, total_cost:)
          return UNKNOWN if usage_source == :unknown

          token_billable = Components::TOKEN_PRICED.any? do |component|
            token_usage.public_send(component.token_key).positive?
          end
          service_billable = false
          service_priced = false
          service_unpriced = false
          service_charges.each do |charge|
            next unless charge.billable?

            service_billable = true
            service_priced ||= charge.priced?
            service_unpriced ||= charge.unpriced?
            break if service_priced && service_unpriced
          end

          priced = (token_billable && !token_cost.nil?) || service_priced || (!token_billable && !service_billable)
          unpriced = (token_billable && token_cost.nil?) || service_unpriced
          return UNKNOWN if unpriced && !priced
          return PARTIAL if unpriced

          total_cost.nil? || total_cost.zero? ? FREE : COMPLETE
        end
        # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      end
    end
  end
end
