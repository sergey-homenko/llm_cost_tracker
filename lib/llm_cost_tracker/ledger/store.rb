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

          insertable = insertable_events(events)

          if insertable.any?
            rows = insertable.map { |event| attributes_for(event) }
            Ledger::Call.insert_all!(rows, record_timestamps: true, returning: false)
            Ledger::Rollups.increment_many!(insertable)
          end
          events
        end

        private

        def attributes_for(event)
          attributes = {
            event_id: event.event_id,
            provider: event.provider,
            model: event.model,
            tags: stored_tags(event.tags),
            tracked_at: event.tracked_at,
            pricing_mode: event.pricing_mode,
            latency_ms: event.latency_ms,
            stream: event.stream,
            usage_source: event.usage_source,
            provider_response_id: event.provider_response_id
          }

          attributes
            .merge(event.token_usage.stored_attributes)
            .merge(Pricing.stored_cost_attributes(event.cost || {}))
        end

        def insertable_events(events)
          existing_ids = Ledger::Call.where(event_id: events.map(&:event_id)).pluck(:event_id).to_set
          seen_ids = Set.new

          events.select do |event|
            event_id = event.event_id
            !existing_ids.include?(event_id) && seen_ids.add?(event_id)
          end
        end

        def stored_tags(tags)
          (tags || {}).transform_keys(&:to_s).transform_values { |value| stored_tag_value(value) }
        end

        def stored_tag_value(value)
          if value.is_a?(Hash)
            return value.transform_keys(&:to_s).transform_values { |nested| stored_tag_value(nested) }
          end

          value.to_s
        end
      end
    end
  end
end
