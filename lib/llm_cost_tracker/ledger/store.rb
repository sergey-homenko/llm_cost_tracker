# frozen_string_literal: true

require_relative "../pricing"
require_relative "../billing/service_charge"
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
            LlmCostTracker::Call.transaction do
              rows = insertable.map { |event| attributes_for(event) }
              LlmCostTracker::Call.insert_all!(rows, record_timestamps: true, returning: false)
              insert_service_charges(insertable)
              Ledger::Rollups.increment_many!(insertable)
            end
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
            pricing_mode: event.pricing_mode&.name,
            latency_ms: event.latency_ms,
            stream: event.stream,
            usage_source: event.usage_source&.name,
            provider_response_id: event.provider_response_id,
            cost_status: event.cost_status,
            pricing_snapshot: event.pricing_snapshot
          }

          attributes
            .merge(event.token_usage.to_h)
            .merge(Pricing.stored_cost_attributes(event.cost || {}))
        end

        def insert_service_charges(events)
          events_with_charges = events.select { |event| event.service_charges.any? }
          return if events_with_charges.empty?

          call_ids = LlmCostTracker::Call
                     .where(event_id: events_with_charges.map(&:event_id))
                     .pluck(:event_id, :id)
                     .to_h
          rows = events_with_charges.flat_map do |event|
            event.service_charges.each_with_index.map do |charge, index|
              service_charge_attributes(
                call_id: call_ids.fetch(event.event_id),
                event_id: event.event_id,
                charge: charge,
                index: index
              )
            end
          end

          LlmCostTracker::ServiceCharge.insert_all!(rows, record_timestamps: true, returning: false) if rows.any?
        end

        def service_charge_attributes(call_id:, event_id:, charge:, index:)
          {
            llm_cost_tracker_call_id: call_id,
            charge_id: charge.charge_id || "#{event_id}:#{index}",
            component: charge.component.name,
            unit: charge.unit.name,
            quantity: charge.quantity,
            rate_amount: charge.rate_amount,
            rate_quantity: charge.rate_quantity,
            cost: charge.cost,
            currency: charge.currency,
            cost_status: charge.cost_status,
            pricing_basis: charge.pricing_basis&.name,
            price_key: charge.price_key,
            price_source: charge.price_source&.name,
            price_source_version: charge.price_source_version,
            source_key: charge.source_key,
            provider_item_id: charge.provider_item_id,
            details: stored_details(charge.details)
          }
        end

        def stored_details(details)
          (details || {}).transform_keys(&:to_s).transform_values { |value| stored_tag_value(value) }
        end

        def insertable_events(events)
          existing_ids = LlmCostTracker::Call.where(event_id: events.map(&:event_id)).pluck(:event_id).to_set
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
