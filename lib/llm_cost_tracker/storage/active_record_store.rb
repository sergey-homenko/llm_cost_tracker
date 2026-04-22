# frozen_string_literal: true

module LlmCostTracker
  module Storage
    class ActiveRecordStore
      class << self
        def save(event)
          tags = stringify_tags(event.tags || {})

          attributes = {
            provider:      event.provider,
            model:         event.model,
            input_tokens:  event.input_tokens,
            output_tokens: event.output_tokens,
            total_tokens:  event.total_tokens,
            input_cost:    event.cost&.input_cost,
            output_cost:   event.cost&.output_cost,
            total_cost:    event.cost&.total_cost,
            tags:          tags_for_storage(tags),
            tracked_at:    event.tracked_at
          }
          attributes[:latency_ms] = event.latency_ms if LlmCostTracker::LlmApiCall.latency_column?
          attributes[:stream] = event.stream if LlmCostTracker::LlmApiCall.stream_column?
          attributes[:usage_source] = event.usage_source if LlmCostTracker::LlmApiCall.usage_source_column?
          if LlmCostTracker::LlmApiCall.provider_response_id_column?
            attributes[:provider_response_id] = event.provider_response_id
          end

          LlmCostTracker::LlmApiCall.create!(attributes)
        end

        def monthly_total(time: Time.now.utc)
          LlmCostTracker::LlmApiCall
            .where(tracked_at: time.beginning_of_month..time)
            .sum(:total_cost)
            .to_f
        end

        private

        def stringify_tags(tags)
          tags.transform_keys(&:to_s).transform_values { |value| stringify_tag_value(value) }
        end

        def tags_for_storage(tags)
          LlmCostTracker::LlmApiCall.tags_json_column? ? tags : tags.to_json
        end

        def stringify_tag_value(value)
          return value.transform_values { |nested| stringify_tag_value(nested) } if value.is_a?(Hash)

          value.to_s
        end
      end
    end
  end
end
