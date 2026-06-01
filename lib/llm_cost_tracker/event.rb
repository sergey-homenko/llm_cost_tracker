# frozen_string_literal: true

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
    :tracked_at,
    :cost_status,
    :pricing_snapshot,
    :line_items
  ) do
    def self.build(**attributes)
      token_usage = attributes.fetch(:token_usage)
      line_items = attributes[:line_items] || resolve_line_items(attributes[:service_line_items])

      new(
        event_id: attributes[:event_id],
        provider: attributes.fetch(:provider).to_s,
        model: attributes.fetch(:model).to_s.strip.presence || Event::UNKNOWN_MODEL,
        token_usage: token_usage,
        pricing_mode: attributes[:pricing_mode],
        cost: attributes[:cost],
        tags: attributes[:tags],
        latency_ms: attributes[:latency_ms],
        stream: attributes[:stream] || false,
        usage_source: attributes[:usage_source]&.to_s,
        provider_response_id: attributes[:provider_response_id].to_s.strip.presence,
        provider_project_id: attributes[:provider_project_id].to_s.strip.presence,
        provider_api_key_id: attributes[:provider_api_key_id].to_s.strip.presence,
        provider_workspace_id: attributes[:provider_workspace_id].to_s.strip.presence,
        tracked_at: attributes[:tracked_at],
        cost_status: attributes[:cost_status],
        pricing_snapshot: attributes[:pricing_snapshot],
        line_items: line_items
      )
    end

    def batch?
      pricing_mode.to_s.split("_").include?("batch")
    end

    def self.resolve_line_items(service_items)
      Array(service_items).map do |item|
        item.is_a?(Charges::LineItem) ? item : Charges::LineItem.build(item)
      end
    end

    def total_cost
      cost&.total
    end

    def to_h
      super.merge(
        token_usage: token_usage.to_h,
        cost: cost&.to_h,
        tags: tags ? tags.to_h : {},
        line_items: (line_items || []).map(&:to_h)
      )
    end
  end

  class Event
    UNKNOWN_MODEL = "unknown"
  end
end
