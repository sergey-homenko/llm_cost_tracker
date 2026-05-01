# frozen_string_literal: true

module LlmCostTracker
  module Billing
    module CostStatus
      COMPLETE = "complete"
      FREE = "free"
      PARTIAL = "partial"
      UNKNOWN = "unknown"
      STATUSES = [COMPLETE, FREE, PARTIAL, UNKNOWN].freeze

      class << self
        def call(token_usage:, usage_source:, token_cost:, service_charges:, total_cost:)
          return UNKNOWN if usage_source.to_s == UNKNOWN

          priced = priced?(token_usage: token_usage, token_cost: token_cost, service_charges: service_charges)
          unpriced = unpriced?(token_usage: token_usage, token_cost: token_cost, service_charges: service_charges)

          return UNKNOWN if unpriced && !priced
          return PARTIAL if unpriced

          total_cost.to_f.zero? ? FREE : COMPLETE
        end

        private

        def priced?(token_usage:, token_cost:, service_charges:)
          token_billable = token_billable?(token_usage)
          service_billable = service_billable?(service_charges)
          service_priced = service_charges.any? { |charge| charge.billable? && charge.priced? }

          (token_billable && token_cost) || service_priced || (!token_billable && !service_billable)
        end

        def unpriced?(token_usage:, token_cost:, service_charges:)
          (token_billable?(token_usage) && token_cost.nil?) ||
            service_charges.any? { |charge| charge.billable? && charge.unpriced? }
        end

        def token_billable?(token_usage)
          token_usage.price_quantities.values.any?(&:positive?)
        end

        def service_billable?(service_charges)
          service_charges.any?(&:billable?)
        end
      end
    end
  end
end
