# frozen_string_literal: true

module LlmCostTracker
  module Storage
    class ActiveRecordStore
      class << self
        def save(event)
          model_class.create!(
            provider:      event[:provider],
            model:         event[:model],
            input_tokens:  event[:input_tokens],
            output_tokens: event[:output_tokens],
            total_tokens:  event[:total_tokens],
            input_cost:    event.dig(:cost, :input_cost),
            output_cost:   event.dig(:cost, :output_cost),
            total_cost:    event.dig(:cost, :total_cost),
            tags:          stringify_tags(event[:tags]).to_json,
            tracked_at:    event[:tracked_at]
          )
        end

        def monthly_total(time: Time.now.utc)
          beginning_of_month = Time.new(time.year, time.month, 1, 0, 0, 0, "+00:00")

          model_class
            .where(tracked_at: beginning_of_month..time)
            .sum(:total_cost)
            .to_f
        end

        def model_class
          LlmCostTracker::LlmApiCall
        end

        private

        def stringify_tags(tags)
          tags.transform_keys(&:to_s).transform_values { |value| stringify_tag_value(value) }
        end

        def stringify_tag_value(value)
          return value.transform_values { |nested| stringify_tag_value(nested) } if value.is_a?(Hash)

          value.to_s
        end
      end
    end
  end
end
