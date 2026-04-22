# frozen_string_literal: true

require_relative "logging"

module LlmCostTracker
  class Tracker
    EVENT_NAME = "llm_request.llm_cost_tracker"

    USAGE_SOURCES = %i[response stream_final manual unknown].freeze

    class << self
      def enforce_budget!
        Budget.enforce!
      end

      def record(provider:, model:, input_tokens:, output_tokens:, latency_ms: nil, stream: false,
                 usage_source: nil, provider_response_id: nil, metadata: {})
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

        event = Event.new(
          provider: provider,
          model: model,
          input_tokens: usage[:input_tokens],
          output_tokens: usage[:output_tokens],
          total_tokens: usage[:total_tokens],
          cost: cost_data,
          tags: LlmCostTracker.configuration.default_tags.merge(EventMetadata.tags(metadata)).freeze,
          latency_ms: normalized_latency_ms(latency_ms),
          stream: stream ? true : false,
          usage_source: normalized_usage_source(usage_source),
          provider_response_id: normalized_provider_response_id(provider_response_id),
          tracked_at: Time.now.utc
        )

        ActiveSupport::Notifications.instrument(EVENT_NAME, event.to_h)

        stored = store(event)
        Budget.check!(event) unless stored == false

        event
      end

      private

      def store(event)
        config = LlmCostTracker.configuration
        case config.storage_backend
        when :log            then log_event(event, config)
        when :active_record  then active_record_save(event)
        when :custom         then custom_save(event, config)
        end
      rescue BudgetExceededError, UnknownPricingError
        raise
      rescue StandardError => e
        handle_storage_error(e)
        false
      end

      def log_event(event, config)
        message = "#{event.provider}/#{event.model} " \
                  "tokens=#{event.input_tokens}+#{event.output_tokens} " \
                  "cost=#{log_cost_label(event)}"
        message += " latency=#{event.latency_ms}ms" if event.latency_ms
        message += " stream=#{event.stream}" if event.stream
        message += " source=#{event.usage_source}" if event.usage_source
        message += " tags=#{event.tags}" unless event.tags.empty?

        Logging.log(config.log_level, message)
        event
      end

      def log_cost_label(event)
        event.cost ? "$#{format('%.6f', event.cost.total_cost)}" : "unknown"
      end

      def active_record_save(event)
        require_relative "llm_api_call" unless defined?(LlmCostTracker::LlmApiCall)
        require_relative "storage/active_record_store" unless defined?(LlmCostTracker::Storage::ActiveRecordStore)

        Storage::ActiveRecordStore.save(event)
        event
      rescue LoadError => e
        raise Error, "ActiveRecord storage requires the active_record gem: #{e.message}"
      end

      def custom_save(event, config)
        result = config.custom_storage&.call(event)
        result == false ? false : event
      end

      def handle_storage_error(error)
        case LlmCostTracker.configuration.storage_error_behavior
        when :ignore
          nil
        when :warn
          Logging.warn("Storage failed; tracking event was not persisted: #{error.class}: #{error.message}")
        when :raise
          storage_error = StorageError.new(error)
          raise storage_error
        end
      end

      def normalized_latency_ms(latency_ms)
        return nil if latency_ms.nil?

        [latency_ms.to_i, 0].max
      end

      def normalized_usage_source(value)
        return nil if value.nil?

        symbol = value.to_sym
        USAGE_SOURCES.include?(symbol) ? symbol.to_s : nil
      end

      def normalized_provider_response_id(value)
        return nil if value.nil?

        string = value.to_s
        string.empty? ? nil : string
      end
    end
  end
end
