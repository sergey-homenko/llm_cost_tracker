# frozen_string_literal: true

require_relative "../logging"
require_relative "registry"
require_relative "active_record_backend"
require_relative "custom_backend"
require_relative "log_backend"

module LlmCostTracker
  module Storage
    class Dispatcher
      class << self
        def save(event)
          backend.save(event)
        rescue LlmCostTracker::BudgetExceededError, LlmCostTracker::UnknownPricingError
          raise
        rescue StandardError => e
          handle_error(e)
          false
        end

        private

        def backend
          Registry.fetch(LlmCostTracker.configuration.storage_backend)
        end

        def handle_error(error)
          case LlmCostTracker.configuration.storage_error_behavior
          when :ignore
            nil
          when :warn
            Logging.warn("Storage failed; tracking event was not persisted: #{error.class}: #{error.message}")
          when :raise
            raise StorageError, error
          end
        end
      end
    end

    Registry.register(:log, LogBackend)
    Registry.register(:active_record, ActiveRecordBackend)
    Registry.register(:custom, CustomBackend)
  end
end
