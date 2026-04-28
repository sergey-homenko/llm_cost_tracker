# frozen_string_literal: true

require_relative "../logging"
require_relative "registry"

module LlmCostTracker
  module Storage
    class LogBackend
      class << self
        def save(event)
          config = LlmCostTracker.configuration
          message = "#{event.provider}/#{event.model} " \
                    "tokens=#{event.total_tokens} " \
                    "cost=#{cost_label(event)}"
          message += " latency=#{event.latency_ms}ms" if event.latency_ms
          message += " stream=#{event.stream}" if event.stream
          message += " source=#{event.usage_source}" if event.usage_source
          message += " tags=#{event.tags}" unless event.tags.empty?

          Logging.log(config.log_level, message)
          event
        end

        def verify
          [
            VerificationResult.new(:ok, "storage", "log backend configured; capture writes to logs only")
          ]
        end

        private

        def cost_label(event)
          event.cost ? "$#{format('%.6f', event.cost.total_cost)}" : "unknown"
        end
      end
    end
  end
end
