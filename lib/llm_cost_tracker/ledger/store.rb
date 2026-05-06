# frozen_string_literal: true

require "json"

require_relative "../pricing"
require_relative "../billing/service_charge"
require_relative "../billing/line_item"
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
              call_ids = call_ids_for(insertable)
              insert_service_charges(insertable, call_ids)
              insert_line_items(insertable, call_ids)
              insert_call_tags(insertable, call_ids)
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
            provider_project_id: event.provider_project_id,
            provider_api_key_id: event.provider_api_key_id,
            provider_workspace_id: event.provider_workspace_id,
            batch: event.batch,
            cost_status: event.cost_status,
            pricing_snapshot: event.pricing_snapshot
          }

          attributes
            .merge(event.token_usage.to_h)
            .merge(Pricing.stored_cost_attributes(event.cost || {}))
        end

        def call_ids_for(events)
          LlmCostTracker::Call
            .where(event_id: events.map(&:event_id))
            .pluck(:event_id, :id)
            .to_h
        end

        def insert_service_charges(events, call_ids)
          events_with_charges = events.select { |event| event.service_charges.any? }
          return if events_with_charges.empty?

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

        def insert_line_items(events, call_ids)
          rows = events.flat_map do |event|
            (event.line_items || []).each_with_index.map do |line_item, position|
              line_item_attributes(
                call_id: call_ids.fetch(event.event_id),
                line_item: line_item,
                position: position
              )
            end
          end
          return if rows.empty?

          LlmCostTracker::CallLineItem.insert_all!(rows, record_timestamps: false, returning: false)
        end

        def line_item_attributes(call_id:, line_item:, position:)
          {
            llm_cost_tracker_call_id: call_id,
            position: position,
            kind: line_item.kind&.to_s,
            direction: line_item.direction&.to_s,
            modality: line_item.modality&.to_s,
            cache_state: line_item.cache_state&.to_s || "none",
            quantity: line_item.quantity,
            unit: line_item.unit&.to_s,
            rate_amount: line_item.rate_amount,
            rate_quantity: line_item.rate_quantity,
            cost: line_item.cost,
            currency: line_item.currency,
            cost_status: line_item.cost_status,
            pricing_basis: line_item.pricing_basis&.to_s,
            price_key: line_item.price_key,
            price_source: line_item.price_source&.to_s,
            price_source_version: line_item.price_source_version,
            provider_field: line_item.provider_field,
            provider_item_id: line_item.provider_item_id,
            details: stored_details(line_item.details),
            created_at: Time.now.utc
          }
        end

        def insert_call_tags(events, call_ids)
          rows = events.flat_map do |event|
            (event.tags || {}).map do |key, value|
              {
                llm_cost_tracker_call_id: call_ids.fetch(event.event_id),
                key: key.to_s,
                value: tag_row_value(value)
              }
            end
          end
          return if rows.empty?

          LlmCostTracker::CallTag.insert_all!(rows, record_timestamps: false, returning: false)
        end

        def tag_row_value(value)
          value.is_a?(Hash) ? JSON.generate(stored_tag_value(value)) : value.to_s
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
