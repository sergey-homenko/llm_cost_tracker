# frozen_string_literal: true

require "json"

require_relative "../pricing"
require_relative "../billing/line_item"
require_relative "rollups"
require_relative "tags/encoding"

module LlmCostTracker
  module Ledger
    class Store
      class << self
        def insert_many(events, skip_existence_check: false)
          events = Array(events)
          return if events.empty?

          insertable = skip_existence_check ? events : insertable_events(events)
          return unless insertable.any?

          LlmCostTracker::Call.transaction do
            rows = insertable.map { |event| attributes_for(event) }
            call_ids = insert_calls_returning_ids(rows, insertable)
            insert_line_items(insertable, call_ids)
            insert_call_tags(insertable, call_ids)
          end
          increment_rollups_safely(insertable) if LlmCostTracker.configuration.cache_rollups
        end

        private

        def insert_calls_returning_ids(rows, insertable)
          if LlmCostTracker::Call.connection.supports_insert_returning?
            result = LlmCostTracker::Call.insert_all!(rows, record_timestamps: true, returning: %i[id event_id])
            result.rows.to_h { |id, event_id| [event_id, id] }
          else
            LlmCostTracker::Call.insert_all!(rows, record_timestamps: true, returning: false)
            call_ids_for(insertable)
          end
        end

        def attributes_for(event)
          attributes = {
            event_id: event.event_id,
            provider: event.provider,
            model: event.model,
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
                value: Tags::Encoding.encode(value)
              }
            end
          end
          return if rows.empty?

          LlmCostTracker::CallTag.insert_all!(rows, record_timestamps: false, returning: false)
        end

        def stored_details(details)
          (details || {}).transform_keys(&:to_s).transform_values { |value| Tags::Encoding.normalize_value(value) }
        end

        def increment_rollups_safely(events)
          Ledger::Rollups.increment_many!(events)
        rescue StandardError => e
          raise if LlmCostTracker::Call.connection.open_transactions.positive?

          LlmCostTracker::Logging.warn(
            "Rollup increment failed for #{events.size} events after ledger commit: #{e.class}: #{e.message}"
          )
        end

        def insertable_events(events)
          existing_ids = LlmCostTracker::Call.where(event_id: events.map(&:event_id)).pluck(:event_id).to_set
          seen_ids = Set.new

          events.select do |event|
            event_id = event.event_id
            !existing_ids.include?(event_id) && seen_ids.add?(event_id)
          end
        end
      end
    end
  end
end
