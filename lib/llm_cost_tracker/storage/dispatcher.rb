# frozen_string_literal: true

require_relative "../logging"

module LlmCostTracker
  module Storage
    class Dispatcher
      class << self
        def save(event)
          config = LlmCostTracker.configuration
          case config.storage_backend
          when :log           then log_event(event, config)
          when :active_record then active_record_save(event)
          when :custom        then custom_save(event, config)
          end
        rescue LlmCostTracker::BudgetExceededError, LlmCostTracker::UnknownPricingError
          raise
        rescue StandardError => e
          handle_error(e)
          false
        end

        private

        def log_event(event, config)
          message = "#{event.provider}/#{event.model} " \
                    "tokens=#{event.total_tokens} " \
                    "cost=#{log_cost_label(event)}"
          message += " latency=#{event.latency_ms}ms" if event.latency_ms
          message += " stream=#{event.stream}" if event.stream
          message += " source=#{event.usage_source}" if event.usage_source
          message += " tags=#{event.tags}" unless event.tags.empty?

          Logging.log(config.log_level, message)
          event
        end

        def log_cost_label(event) = event.cost ? "$#{format('%.6f', event.cost.total_cost)}" : "unknown"

        def active_record_save(event)
          require_relative "../llm_api_call" unless defined?(LlmCostTracker::LlmApiCall)
          require_relative "active_record_store" unless defined?(LlmCostTracker::Storage::ActiveRecordStore)

          ActiveRecordStore.save(event)
          event
        rescue LoadError => e
          raise Error, "ActiveRecord storage requires the active_record gem: #{e.message}"
        end

        def custom_save(event, config)
          result = config.custom_storage&.call(event)
          result == false ? false : event
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
  end
end
