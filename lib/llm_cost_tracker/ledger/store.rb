# frozen_string_literal: true

require_relative "../pricing"
require_relative "rollups"

module LlmCostTracker
  module Ledger
    class Store
      class << self
        def insert_many(events)
          events = Array(events)
          return [] if events.empty?

          model = LlmCostTracker::Ledger::Call
          insertable = new_events(model, events)

          if insertable.any?
            rows = insertable.map { |event| attributes_for(event) }
            model.insert_all!(rows, record_timestamps: true, returning: false)
            Ledger::Rollups.increment_many!(insertable)
          end
          events
        end

        private

        def attributes_for(event)
          tags = (event.tags || {}).transform_keys(&:to_s).transform_values { |value| stringify_tag_value(value) }
          usage = event.token_usage.stored_attributes

          attributes = {
            event_id: event.event_id,
            provider: event.provider,
            model: event.model,
            tags: tags,
            tracked_at: event.tracked_at,
            pricing_mode: event.pricing_mode,
            latency_ms: event.latency_ms,
            stream: event.stream,
            usage_source: event.usage_source,
            provider_response_id: event.provider_response_id
          }

          attributes.merge(usage).merge(Pricing.stored_cost_attributes(event.cost || {}))
        end

        def new_events(model, events)
          existing_ids = model.where(event_id: events.map(&:event_id)).pluck(:event_id).to_set
          events.reject { |event| existing_ids.include?(event.event_id) }
        end

        def stringify_tag_value(value)
          return value.transform_values { |nested| stringify_tag_value(nested) } if value.is_a?(Hash)

          value.to_s
        end
      end
    end
  end
end
