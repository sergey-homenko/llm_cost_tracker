# frozen_string_literal: true

require "active_support/core_ext/digest/uuid"

require_relative "pricing/mode"

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
  )

  class Event
    UNKNOWN_MODEL = "unknown"
    PROVIDER_IDS = %i[provider_response_id provider_project_id provider_api_key_id provider_workspace_id].freeze
    PASSTHROUGH_FIELDS = %i[event_id pricing_mode cost tags latency_ms tracked_at cost_status pricing_snapshot].freeze
    private_constant :PROVIDER_IDS, :PASSTHROUGH_FIELDS

    def self.build(**attributes)
      new(
        token_usage: attributes.fetch(:token_usage),
        line_items: attributes[:line_items] || resolve_line_items(attributes[:service_line_items]),
        provider: attributes.fetch(:provider).to_s,
        model: identifier(attributes.fetch(:model)) || UNKNOWN_MODEL,
        stream: attributes[:stream] || false,
        usage_source: attributes[:usage_source]&.to_s,
        **PASSTHROUGH_FIELDS.to_h { |field| [field, attributes[field]] },
        **PROVIDER_IDS.to_h { |field| [field, identifier(attributes[field])] }
      )
    end

    def self.resolve_line_items(service_items)
      Array(service_items).map do |item|
        item.is_a?(Charges::LineItem) ? item : Charges::LineItem.build(item)
      end
    end

    def self.identifier(value) = value.to_s.strip.presence
    private_class_method :identifier

    def batch?
      Pricing::Mode.tokenize(pricing_mode.to_s).include?("batch")
    end

    def keyed_by_response_id
      return self unless provider_response_id

      with(event_id: Digest::UUID.uuid_v5(Digest::UUID::OID_NAMESPACE, "#{provider}/#{provider_response_id}"))
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
end
