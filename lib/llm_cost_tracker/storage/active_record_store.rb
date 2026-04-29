# frozen_string_literal: true

require_relative "active_record_inbox"
require_relative "active_record_period_totals"
require_relative "active_record_rollups"

module LlmCostTracker
  module Storage
    class ActiveRecordStore
      class << self
        def reset!
          ActiveRecordRollups.reset!
        end

        def save(event)
          model = LlmCostTracker::LlmApiCall
          attributes = attributes_for(event, model)

          model.transaction do
            call = model.create!(attributes)
            ActiveRecordRollups.increment!(event)
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
            model.insert_all!(rows, **insert_options)
            ActiveRecordRollups.increment_many!(insertable)
          end
          events
        end

        def attributes_for(event, model = LlmCostTracker::LlmApiCall)
          tags = stringify_tags(event.tags || {})
          columns = model.columns_hash

          attributes = {
            provider:      event.provider,
            model:         event.model,
            input_tokens:  event.input_tokens,
            output_tokens: event.output_tokens,
            total_tokens:  event.total_tokens,
            input_cost:    event.cost&.input_cost,
            output_cost:   event.cost&.output_cost,
            total_cost:    event.cost&.total_cost,
            tags:          tags_for_storage(tags, model),
            tracked_at:    event.tracked_at
          }
          attributes[:event_id] = event.event_id if columns.key?("event_id")
          optional_attributes(event).each do |name, value|
            attributes[name] = value if columns.key?(name.to_s)
          end
          attributes[:latency_ms] = event.latency_ms if columns.key?("latency_ms")
          attributes[:stream] = event.stream if columns.key?("stream")
          attributes[:usage_source] = event.usage_source if columns.key?("usage_source")
          attributes[:provider_response_id] = event.provider_response_id if columns.key?("provider_response_id")

          attributes
        end

        def monthly_total(time: Time.now.utc)
          period_totals(%i[monthly], time: time).fetch(:monthly)
        end

        def daily_total(time: Time.now.utc)
          period_totals(%i[daily], time: time).fetch(:daily)
        end

        def period_totals(periods, time: Time.now.utc)
          ActiveRecordPeriodTotals.call(periods, time: time)
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

        def insert_options = { record_timestamps: true, returning: false }

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
            ActiveRecordRollups.decrement!(rows) if deleted.positive?
            deleted
          end
        end

        def stringify_tags(tags)
          tags.transform_keys(&:to_s).transform_values { |value| stringify_tag_value(value) }
        end

        def tags_for_storage(tags, model)
          model.tags_json_column? ? tags : tags.to_json
        end

        def optional_attributes(event)
          {
            cache_read_input_tokens: event.cache_read_input_tokens,
            cache_write_input_tokens: event.cache_write_input_tokens,
            hidden_output_tokens: event.hidden_output_tokens,
            cache_read_input_cost: event.cost&.cache_read_input_cost,
            cache_write_input_cost: event.cost&.cache_write_input_cost,
            pricing_mode: event.pricing_mode
          }
        end

        def stringify_tag_value(value)
          return value.transform_values { |nested| stringify_tag_value(nested) } if value.is_a?(Hash)

          value.to_s
        end
      end
    end
  end
end
