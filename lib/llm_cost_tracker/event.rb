# frozen_string_literal: true

require_relative "pricing"
require_relative "billing/line_item"

module LlmCostTracker
  Event = Data.define(
    :event_id,
    :provider,
    :model,
    :token_usage,
    :pricing_mode,
    :cost,
    :tags,
    :latency_ms,
    :stream,
    :usage_source,
    :provider_response_id,
    :provider_project_id,
    :provider_api_key_id,
    :provider_workspace_id,
    :batch,
    :tracked_at,
    :cost_status,
    :pricing_snapshot,
    :line_items
  ) do
    def self.batch_from_pricing_mode?(pricing_mode)
      pricing_mode.to_s.split("_").include?("batch")
    end

    def self.build(**attributes)
      pricing_mode = Pricing.normalize_mode(attributes[:pricing_mode])
      token_usage = attributes.fetch(:token_usage)
      batch = attributes[:batch].nil? ? batch_from_pricing_mode?(pricing_mode) : attributes[:batch]
      line_items = attributes[:line_items] || resolve_line_items(attributes[:service_line_items], token_usage)

      new(
        event_id: attributes[:event_id],
        provider: attributes.fetch(:provider).to_s,
        model: attributes.fetch(:model).to_s.strip.presence || Event::UNKNOWN_MODEL,
        token_usage: token_usage,
        pricing_mode: pricing_mode,
        cost: attributes[:cost],
        tags: attributes[:tags],
        latency_ms: attributes[:latency_ms],
        stream: attributes[:stream] || false,
        usage_source: attributes[:usage_source],
        provider_response_id: attributes[:provider_response_id].to_s.strip.presence,
        provider_project_id: attributes[:provider_project_id].to_s.strip.presence,
        provider_api_key_id: attributes[:provider_api_key_id].to_s.strip.presence,
        provider_workspace_id: attributes[:provider_workspace_id].to_s.strip.presence,
        batch: batch,
        tracked_at: attributes[:tracked_at],
        cost_status: attributes[:cost_status],
        pricing_snapshot: attributes[:pricing_snapshot],
        line_items: line_items
      )
    end

    def self.resolve_line_items(service_items, token_usage)
      service_line_items = Array(service_items).map do |item|
        item.is_a?(Billing::LineItem) ? item : Billing::LineItem.build(item)
      end
      Billing::LineItem.from_token_usage(token_usage) + service_line_items
    end

    def total_cost
      cost&.fetch(:total_cost, nil)
    end

    def to_h
      super.merge(
        token_usage: token_usage.to_h,
        cost: cost && cost.to_h.transform_values { |v| v.is_a?(BigDecimal) ? v.to_f : v },
        tags: tags ? tags.to_h : {},
        line_items: (line_items || []).map(&:to_h)
      )
    end
  end

  class Event
    UNKNOWN_MODEL = "unknown"
  end
end
