# frozen_string_literal: true

require_relative "../logging"

module LlmCostTracker
  module Storage
    module LogBackend
      class << self
        def save(event, config:)
          message = "#{event.provider}/#{event.model} " \
                    "tokens=#{event.input_tokens}+#{event.output_tokens} " \
                    "cost=#{cost_label(event)}"
          message += " latency=#{event.latency_ms}ms" if event.latency_ms
          message += " tags=#{event.tags}" unless event.tags.empty?

          Logging.log(config.log_level, message)
          event
        end

        private

        def cost_label(event)
          event.cost ? "$#{format('%.6f', event.cost.total_cost)}" : "unknown"
        end
      end
    end
  end
end
