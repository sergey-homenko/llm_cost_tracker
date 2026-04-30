# frozen_string_literal: true

require "active_support/core_ext/object/blank"

module LlmCostTracker
  UsageCapture = Data.define(
    :provider,
    :model,
    :token_usage,
    :stream,
    :usage_source,
    :provider_response_id
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
        provider_response_id: attributes[:provider_response_id]
      )
    end

    def to_h
      super.compact
    end
  end
end
