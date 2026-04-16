# frozen_string_literal: true

module LlmCostTracker
  class Tracker
    EVENT_NAME = "llm_request.llm_cost_tracker"

    class << self
      def record(provider:, model:, input_tokens:, output_tokens:, metadata: {})
        cost_data = Pricing.cost_for(
          model: model,
          input_tokens: input_tokens,
          output_tokens: output_tokens
        )

        event = {
          provider: provider,
          model: model,
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          total_tokens: input_tokens + output_tokens,
          cost: cost_data,
          tags: LlmCostTracker.configuration.default_tags.merge(metadata),
          tracked_at: Time.now.utc
        }

        # Emit ActiveSupport::Notifications event
        ActiveSupport::Notifications.instrument(EVENT_NAME, event)

        # Store based on backend
        store(event)

        # Budget check
        check_budget(event)

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
      end

      def log_event(event)
        cost_str = event[:cost] ? "$#{'%.6f' % event[:cost][:total_cost]}" : "unknown"

        message = "[LlmCostTracker] #{event[:provider]}/#{event[:model]} " \
                  "tokens=#{event[:input_tokens]}+#{event[:output_tokens]} " \
                  "cost=#{cost_str}"
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

      def store_active_record(event)
        return unless defined?(LlmCostTracker::Storage::ActiveRecordStore)

        LlmCostTracker::Storage::ActiveRecordStore.save(event)
      end

      def check_budget(event)
        config = LlmCostTracker.configuration
        return unless config.monthly_budget && config.on_budget_exceeded
        return unless event[:cost]

        monthly_total = calculate_monthly_total(event[:cost][:total_cost])
        return unless monthly_total > config.monthly_budget

        config.on_budget_exceeded.call(
          monthly_total: monthly_total,
          budget: config.monthly_budget,
          last_event: event
        )
      end

      def calculate_monthly_total(latest_cost)
        # For :active_record backend, query the DB
        if LlmCostTracker.configuration.active_record? &&
           defined?(LlmCostTracker::Storage::ActiveRecordStore)
          LlmCostTracker::Storage::ActiveRecordStore.monthly_total + latest_cost
        else
          # For other backends, we can only report the latest cost
          latest_cost
        end
      end
    end
  end
end
