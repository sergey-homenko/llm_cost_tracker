# frozen_string_literal: true

require "active_support/core_ext/object/blank"

module LlmCostTracker
  ParsedUsage = Data.define(
    :provider,
    :model,
    :token_usage,
    :stream,
    :usage_source,
    :provider_response_id
  )

  class ParsedUsage
    UNKNOWN_MODEL = "unknown"

    def self.build(**attributes)
      new(
        provider: attributes.fetch(:provider),
        model: attributes.fetch(:model).to_s.strip.presence || UNKNOWN_MODEL,
        token_usage: attributes.fetch(:token_usage),
        stream: attributes[:stream] || false,
        usage_source: attributes[:usage_source],
        provider_response_id: attributes[:provider_response_id]
      )
    end

    def to_h
      values = super.compact
      usage = values.delete(:token_usage)
      values.merge(usage.to_h)
    end
  end
end
