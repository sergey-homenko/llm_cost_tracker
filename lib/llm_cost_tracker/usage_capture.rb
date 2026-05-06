# frozen_string_literal: true

require "active_support/core_ext/object/blank"

require_relative "pricing"
require_relative "billing/line_item"

module LlmCostTracker
  UsageCapture = Data.define(
    :provider,
    :model,
    :token_usage,
    :stream,
    :usage_source,
    :provider_response_id,
    :provider_project_id,
    :provider_api_key_id,
    :provider_workspace_id,
    :batch,
    :pricing_mode,
    :line_items
  )

  class UsageCapture
    UNKNOWN_MODEL = "unknown"

    def self.batch_from_pricing_mode?(pricing_mode)
      pricing_mode.to_s.split("_").include?("batch")
    end

    def self.build(**attributes)
      pricing_mode = Pricing.normalize_mode(attributes[:pricing_mode])
      batch = attributes[:batch]
      batch = batch_from_pricing_mode?(pricing_mode) if batch.nil?

      token_usage = attributes.fetch(:token_usage)
      service_line_items = Array(attributes[:service_line_items]).map do |item|
        item.is_a?(Billing::LineItem) ? item : Billing::LineItem.build(item)
      end
      line_items = attributes[:line_items] || (Billing::LineItem.from_token_usage(token_usage) + service_line_items)

      new(
        provider: attributes.fetch(:provider).to_s,
        model: attributes.fetch(:model).to_s.strip.presence || UNKNOWN_MODEL,
        token_usage: token_usage,
        stream: attributes[:stream] || false,
        usage_source: attributes[:usage_source],
        provider_response_id: attributes[:provider_response_id].to_s.strip.presence,
        provider_project_id: attributes[:provider_project_id].to_s.strip.presence,
        provider_api_key_id: attributes[:provider_api_key_id].to_s.strip.presence,
        provider_workspace_id: attributes[:provider_workspace_id].to_s.strip.presence,
        batch: batch,
        pricing_mode: pricing_mode,
        line_items: line_items
      )
    end
  end
end
