# frozen_string_literal: true

require_relative "../errors"
require_relative "../logging"
require_relative "active_record_backend"

module LlmCostTracker
  module Storage
    class Writer
      class << self
        def save(event)
          ActiveRecordBackend.save(event)
        rescue LlmCostTracker::BudgetExceededError, LlmCostTracker::UnknownPricingError
          raise
        rescue StandardError => e
          handle_error(e)
          false
        end

        private

        def handle_error(error)
          case LlmCostTracker.configuration.storage_error_behavior
          when :ignore
            nil
          when :warn
            Logging.warn("ActiveRecord ledger write failed: #{error.class}: #{error.message}")
          when :raise
            raise StorageError, error
          end
        end
      end
    end
  end
end
