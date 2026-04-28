# frozen_string_literal: true

require_relative "registry"

module LlmCostTracker
  module Storage
    class CustomBackend
      class << self
        def save(event)
          result = LlmCostTracker.configuration.custom_storage&.call(event)
          result == false ? false : event
        end

        def verify
          if LlmCostTracker.configuration.custom_storage.respond_to?(:call)
            return [
              VerificationResult.new(
                :ok,
                "storage",
                "custom storage callable configured; external sink was not invoked"
              )
            ]
          end

          [
            VerificationResult.new(:error, "storage", "custom storage backend requires config.custom_storage")
          ]
        end
      end
    end
  end
end
