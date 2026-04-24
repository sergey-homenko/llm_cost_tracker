# frozen_string_literal: true

require_relative "active_record_rollups"

module LlmCostTracker
  module Storage
    class ActiveRecordStore
      class << self
        def reset!
          ActiveRecordRollups.reset!
        end

        def save(event)
          tags = stringify_tags(event.tags || {})
          model = LlmCostTracker::LlmApiCall
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
          optional_attributes(event).each do |name, value|
            attributes[name] = value if columns.key?(name.to_s)
          end
          attributes[:latency_ms] = event.latency_ms if columns.key?("latency_ms")
          attributes[:stream] = event.stream if columns.key?("stream")
          attributes[:usage_source] = event.usage_source if columns.key?("usage_source")
          attributes[:provider_response_id] = event.provider_response_id if columns.key?("provider_response_id")

          model.transaction do
            call = model.create!(attributes)
            ActiveRecordRollups.increment!(event)
            call
          end
        end

        def monthly_total(time: Time.now.utc)
          ActiveRecordRollups.monthly_total(time: time)
        end

        def daily_total(time: Time.now.utc)
          ActiveRecordRollups.daily_total(time: time)
        end

        def period_totals(periods, time: Time.now.utc)
          ActiveRecordRollups.period_totals(periods, time: time)
        end

        private

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
