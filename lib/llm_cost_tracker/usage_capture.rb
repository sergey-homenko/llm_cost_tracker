# frozen_string_literal: true

require "active_support/core_ext/object/blank"

require_relative "pricing"
require_relative "billing/service_charge"

module LlmCostTracker
  UsageCapture = Data.define(
    :provider,
    :model,
    :token_usage,
    :stream,
    :usage_source,
    :provider_response_id,
    :pricing_mode,
    :service_charges
  )

  class UsageCapture
    UNKNOWN_MODEL = "unknown"

    def self.build(**attributes)
      new(
        provider: attributes.fetch(:provider).to_s,
        model: attributes.fetch(:model).to_s.strip.presence || UNKNOWN_MODEL,
        token_usage: attributes.fetch(:token_usage),
        stream: attributes[:stream] || false,
        usage_source: attributes[:usage_source],
        provider_response_id: attributes[:provider_response_id],
        pricing_mode: Pricing.normalize_mode(attributes[:pricing_mode]),
        service_charges: Billing::ServiceCharge.build_many(attributes[:service_charges])
      )
    end
  end
end
