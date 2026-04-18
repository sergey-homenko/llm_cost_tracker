# frozen_string_literal: true

module LlmCostTracker
  class Tracker
    EVENT_NAME = "llm_request.llm_cost_tracker"

    class << self
      def enforce_budget!
        Budget.enforce!
      end

      def record(provider:, model:, input_tokens:, output_tokens:, metadata: {}, latency_ms: nil)
        usage = EventMetadata.usage_data(input_tokens, output_tokens, metadata)

        cost_data = Pricing.cost_for(
          model: model,
          input_tokens: usage[:input_tokens],
          output_tokens: usage[:output_tokens],
          cached_input_tokens: usage[:cached_input_tokens],
          cache_read_input_tokens: usage[:cache_read_input_tokens],
          cache_creation_input_tokens: usage[:cache_creation_input_tokens]
        )

        UnknownPricing.handle!(model) unless cost_data

        event = {
          provider: provider,
          model: model,
          input_tokens: usage[:input_tokens],
          output_tokens: usage[:output_tokens],
          total_tokens: usage[:total_tokens],
          cost: cost_data,
          tags: LlmCostTracker.configuration.default_tags.merge(EventMetadata.tags(metadata)),
          latency_ms: normalized_latency_ms(latency_ms),
          tracked_at: Time.now.utc
        }

        # Emit ActiveSupport::Notifications event
        ActiveSupport::Notifications.instrument(EVENT_NAME, event)

        # Store based on backend
        stored = store(event)
        Budget.check!(event) unless stored == false

        event
      end

      private

      def store(event)
        config = LlmCostTracker.configuration

        case config.storage_backend
        when :log
          log_event(event)
        when :active_record
          store_active_record(event)
        when :custom
          config.custom_storage&.call(event)
        end

        true
      rescue BudgetExceededError, UnknownPricingError
        raise
      rescue StandardError => e
        handle_storage_error(e)
        false
      end

      def log_event(event)
        cost_str = event[:cost] ? "$#{format('%.6f', event[:cost][:total_cost])}" : "unknown"

        message = "[LlmCostTracker] #{event[:provider]}/#{event[:model]} " \
                  "tokens=#{event[:input_tokens]}+#{event[:output_tokens]} " \
                  "cost=#{cost_str}"
        message += " latency=#{event[:latency_ms]}ms" if event[:latency_ms]
        message += " tags=#{event[:tags]}" unless event[:tags].empty?

        case LlmCostTracker.configuration.log_level
        when :debug
          Rails.logger.debug(message) if defined?(Rails)
        when :warn
          Rails.logger.warn(message) if defined?(Rails)
        else
          Rails.logger.info(message) if defined?(Rails)
        end

        # Fallback if Rails is not available
        warn(message) unless defined?(Rails)
      end

      def log_warning(message)
        message = "[LlmCostTracker] #{message}"

        if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
          Rails.logger.warn(message)
        else
          warn message
        end
      end

      def store_active_record(event)
        require_relative "llm_api_call" unless defined?(LlmCostTracker::LlmApiCall)
        require_relative "storage/active_record_store" unless defined?(LlmCostTracker::Storage::ActiveRecordStore)

        LlmCostTracker::Storage::ActiveRecordStore.save(event)
      rescue LoadError => e
        raise Error, "ActiveRecord storage requires the active_record gem: #{e.message}"
      end

      def handle_storage_error(error)
        case storage_error_behavior
        when :ignore
          nil
        when :warn
          log_warning("Storage failed; tracking event was not persisted: #{error.class}: #{error.message}")
        when :raise
          storage_error = StorageError.new(error)
          raise storage_error
        end
      end

      def storage_error_behavior
        behavior = (LlmCostTracker.configuration.storage_error_behavior || :warn).to_sym
        return behavior if Configuration::STORAGE_ERROR_BEHAVIORS.include?(behavior)

        raise Error,
              "Unknown storage_error_behavior: #{behavior.inspect}. " \
              "Use one of: #{Configuration::STORAGE_ERROR_BEHAVIORS.join(', ')}"
      end

      def normalized_latency_ms(latency_ms)
        return nil if latency_ms.nil?

        [latency_ms.to_i, 0].max
      end
    end
  end
end
