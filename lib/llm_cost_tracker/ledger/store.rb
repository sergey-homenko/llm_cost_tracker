# frozen_string_literal: true

require_relative "ingestion/inbox"
require_relative "period_totals"
require_relative "rollups"

module LlmCostTracker
  class Ledger
    class Store
      class << self
        def reset!
          Ledger::Rollups.reset!
        end

        def save(event)
          model = LlmCostTracker::Ledger::Call
          attributes = attributes_for(event)

          model.transaction do
            call = model.create!(attributes)
            Ledger::Rollups.increment!(event)
            call
          end
        end

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

          attributes.merge(usage).merge(TokenUsage.stored_cost_attributes(event.cost || {}))
        end

        def monthly_total(time: Time.now.utc)
          period_totals(%i[monthly], time: time).fetch(:monthly)
        end

        def daily_total(time: Time.now.utc)
          period_totals(%i[daily], time: time).fetch(:daily)
        end

        def period_totals(periods, time: Time.now.utc)
          Ledger::PeriodTotals.call(periods, time: time)
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
          existing_ids = model.where(event_id: events.map(&:event_id)).pluck(:event_id).to_set
          events.reject { |event| existing_ids.include?(event.event_id) }
        end

        def prune_batch(cutoff, batch_size)
          LlmCostTracker::Ledger::Call.transaction do
            rows = LlmCostTracker::Ledger::Call
                   .where(tracked_at: ...cutoff)
                   .order(:id)
                   .limit(batch_size)
                   .lock
                   .pluck(:id, :tracked_at, :total_cost)
            next 0 if rows.empty?

            deleted = LlmCostTracker::Ledger::Call.where(id: rows.map(&:first)).delete_all
            Ledger::Rollups.decrement!(rows) if deleted.positive?
            deleted
          end
        end

        def stringify_tag_value(value)
          return value.transform_values { |nested| stringify_tag_value(nested) } if value.is_a?(Hash)

          value.to_s
        end
      end
    end
  end
end
