# frozen_string_literal: true

module LlmCostTracker
  class Budget
    class << self
      WARNING_MUTEX = Mutex.new

      def enforce!
        return unless LlmCostTracker.configuration.monthly_budget
        return unless behavior == :block_requests
        return warn_non_active_record_block_requests unless LlmCostTracker.configuration.active_record?

        monthly_total = calculate_monthly_total(0)
        return unless monthly_total >= LlmCostTracker.configuration.monthly_budget

        handle_exceeded(monthly_total: monthly_total)
      end

      def check!(event)
        config = LlmCostTracker.configuration
        return unless config.monthly_budget
        return unless event[:cost]

        monthly_total = calculate_monthly_total(event[:cost][:total_cost])
        return unless monthly_total > config.monthly_budget

        handle_exceeded(monthly_total: monthly_total, last_event: event)
      end

      private

      def calculate_monthly_total(latest_cost)
        if LlmCostTracker.configuration.active_record?
          active_record_monthly_total
        else
          latest_cost
        end
      end

      def active_record_monthly_total
        require_relative "llm_api_call" unless defined?(LlmCostTracker::LlmApiCall)
        require_relative "storage/active_record_store" unless defined?(LlmCostTracker::Storage::ActiveRecordStore)

        LlmCostTracker::Storage::ActiveRecordStore.monthly_total
      rescue LoadError => e
        raise Error, "ActiveRecord storage requires the active_record gem: #{e.message}"
      end

      def warn_non_active_record_block_requests
        should_warn = WARNING_MUTEX.synchronize do
          unless @warned_non_active_record_block_requests
            @warned_non_active_record_block_requests = true
            true
          end
        end
        return unless should_warn

        log_warning(":block_requests preflight requires storage_backend = :active_record; request was not blocked.")
      end

      def handle_exceeded(monthly_total:, last_event: nil)
        config = LlmCostTracker.configuration
        payload = {
          monthly_total: monthly_total,
          budget: config.monthly_budget,
          last_event: last_event
        }

        config.on_budget_exceeded&.call(payload)
        raise BudgetExceededError.new(**payload) if raise_on_exceeded?
      end

      def raise_on_exceeded?
        %i[raise block_requests].include?(behavior)
      end

      def behavior
        behavior = (LlmCostTracker.configuration.budget_exceeded_behavior || :notify).to_sym
        return behavior if Configuration::BUDGET_EXCEEDED_BEHAVIORS.include?(behavior)

        raise Error,
              "Unknown budget_exceeded_behavior: #{behavior.inspect}. " \
              "Use one of: #{Configuration::BUDGET_EXCEEDED_BEHAVIORS.join(', ')}"
      end

      def log_warning(message)
        message = "[LlmCostTracker] #{message}"

        if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
          Rails.logger.warn(message)
        else
          warn message
        end
      end
    end
  end
end
