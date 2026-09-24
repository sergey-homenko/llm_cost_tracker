# frozen_string_literal: true

require "json"

require_relative "../pricing"
require_relative "rollups"
require_relative "../budget/per_tag"
require_relative "tags/encoding"
require_relative "storable"

module LlmCostTracker
  module Ledger
    module Store
      class << self
        def insert(events)
          events = Array(events)
          return if events.empty?

          persist_records(events)
          Ledger::Rollups.increment_safely!(events)
        end

        def persist_records(events)
          events = Array(events)
          return if events.empty?

          Isolation.transaction do
            rows = events.map { |event| attributes_for(event) }
            call_ids = insert_calls_returning_ids(rows, events)
            insert_line_items(events, call_ids)
            insert_call_tags(events, call_ids)
          end
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
            provider: Storable.identifier(event.provider),
            model: Storable.identifier(event.model),
            tracked_at: event.tracked_at,
            pricing_mode: Storable.identifier(event.pricing_mode),
            latency_ms: event.latency_ms,
            stream: event.stream,
            usage_source: Storable.identifier(event.usage_source),
            provider_response_id: Storable.identifier(event.provider_response_id),
            provider_project_id: Storable.identifier(event.provider_project_id),
            provider_api_key_id: Storable.identifier(event.provider_api_key_id),
            provider_workspace_id: Storable.identifier(event.provider_workspace_id),
            batch: event.batch?,
            cost_status: event.cost_status,
            pricing_snapshot: event.pricing_snapshot
          }

          attributes
            .merge(Storable.token_counts(event.token_usage, event_id: event.event_id))
            .merge(total_cost: event.cost&.total)
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
          strings = Storable::LINE_ITEM_STRINGS.to_h do |member|
            [member, Storable.identifier(line_item.public_send(member))]
          end
          strings.merge(
            llm_cost_tracker_call_id: call_id,
            position: position,
            quantity: line_item.quantity,
            rate_amount: line_item.rate_amount,
            rate_quantity: line_item.rate_quantity,
            cost: line_item.cost,
            details: stored_details(line_item.details),
            created_at: Time.now.utc
          )
        end

        def insert_call_tags(events, call_ids)
          rows = events.flat_map do |event|
            (event.tags || {}).map do |key, value|
              {
                llm_cost_tracker_call_id: call_ids.fetch(event.event_id),
                key: key.to_s,
                value: Tags::Encoding.encode(value)
              }.merge(budget_columns_for(event))
            end
          end
          return if rows.empty?

          LlmCostTracker::CallTag.insert_all!(rows, record_timestamps: false, returning: false)
        end

        def budget_columns_for(event)
          return {} unless LlmCostTracker::Budget::PerTag.columns?

          { total_cost: event.cost&.total, tracked_at: event.tracked_at }
        end

        def stored_details(details)
          (details || {}).transform_keys(&:to_s).transform_values { |value| Tags::Encoding.normalize_value(value) }
        end
      end
    end
  end
end
