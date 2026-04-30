# frozen_string_literal: true

require "active_support/core_ext/hash/except"

require_relative "inbox"
require_relative "period_totals"
require_relative "rollups"

module LlmCostTracker
  class LedgerStore
    class << self
      def reset!
        Rollups.reset!
      end

      def save(event)
        model = LlmCostTracker::LlmApiCall
        attributes = attributes_for(event, model)

        model.transaction do
          call = model.create!(attributes)
          Rollups.increment!(event)
          call
        end
      end

      def insert_many(events)
        events = Array(events)
        return [] if events.empty?

        model = LlmCostTracker::LlmApiCall
        insertable = new_events(model, events)

        if insertable.any?
          rows = insertable.map { |event| attributes_for(event, model) }
          model.insert_all!(rows, record_timestamps: true, returning: false)
          Rollups.increment_many!(insertable)
        end
        events
      end

      def attributes_for(event, model = LlmCostTracker::LlmApiCall)
        tags = (event.tags || {}).transform_keys(&:to_s).transform_values { |value| stringify_tag_value(value) }
        columns = model.columns_hash
        usage = event.token_usage.stored_attributes

        attributes = {
          provider: event.provider,
          model: event.model,
          tags: model.tags_json_column? ? tags : tags.to_json,
          tracked_at: event.tracked_at
        }

        add_stored_attributes(attributes, columns, usage, TokenUsage::BASE_STORED_KEYS)
        add_stored_attributes(attributes, columns, event.cost&.stored_attributes || {}, Cost::BASE_STORED_KEYS)

        {
          event_id: event.event_id,
          pricing_mode: event.pricing_mode,
          latency_ms: event.latency_ms,
          stream: event.stream,
          usage_source: event.usage_source,
          provider_response_id: event.provider_response_id
        }.each do |name, value|
          attributes[name] = value if columns.key?(name.to_s)
        end

        attributes
      end

      def monthly_total(time: Time.now.utc)
        period_totals(%i[monthly], time: time).fetch(:monthly)
      end

      def daily_total(time: Time.now.utc)
        period_totals(%i[daily], time: time).fetch(:daily)
      end

      def period_totals(periods, time: Time.now.utc)
        PeriodTotals.call(periods, time: time)
      end

      def prune(cutoff:, batch_size:)
        deleted = 0
        loop do
          batch = prune_batch(cutoff, batch_size)
          deleted += batch
          break if batch < batch_size
        end
        deleted
      end

      private

      def new_events(model, events)
        return events unless model.columns_hash.key?("event_id")

        existing_ids = model.where(event_id: events.map(&:event_id)).pluck(:event_id).to_set
        events.reject { |event| existing_ids.include?(event.event_id) }
      end

      def prune_batch(cutoff, batch_size)
        LlmCostTracker::LlmApiCall.transaction do
          rows = LlmCostTracker::LlmApiCall
                 .where(tracked_at: ...cutoff)
                 .order(:id)
                 .limit(batch_size)
                 .lock
                 .pluck(:id, :tracked_at, :total_cost)
          next 0 if rows.empty?

          deleted = LlmCostTracker::LlmApiCall.where(id: rows.map(&:first)).delete_all
          Rollups.decrement!(rows) if deleted.positive?
          deleted
        end
      end

      def stringify_tag_value(value)
        return value.transform_values { |nested| stringify_tag_value(nested) } if value.is_a?(Hash)

        value.to_s
      end

      def add_stored_attributes(attributes, columns, values, required)
        values.each do |name, value|
          attributes[name] = value if required.include?(name) || columns.key?(name.to_s)
        end
      end
    end
  end
end
