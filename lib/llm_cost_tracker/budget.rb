# frozen_string_literal: true

require_relative "logging"

module LlmCostTracker
  class Budget
    class << self
      def enforce!
        config = LlmCostTracker.configuration
        return unless config.monthly_budget
        return unless config.budget_exceeded_behavior == :block_requests
        return unless config.active_record?

        monthly_total = active_record_monthly_total
        return unless monthly_total >= config.monthly_budget

        handle_exceeded(monthly_total: monthly_total)
      end

      def check!(event)
        config = LlmCostTracker.configuration
        return unless config.monthly_budget
        return unless event.cost

        monthly_total = if config.active_record?
                          active_record_monthly_total
                        else
                          event.cost.total_cost
                        end
        return unless monthly_total > config.monthly_budget

        handle_exceeded(monthly_total: monthly_total, last_event: event)
      end

      private

      def active_record_monthly_total
        require_relative "llm_api_call" unless defined?(LlmCostTracker::LlmApiCall)
        require_relative "storage/active_record_store" unless defined?(LlmCostTracker::Storage::ActiveRecordStore)

        LlmCostTracker::Storage::ActiveRecordStore.monthly_total
      rescue LoadError => e
        raise Error, "ActiveRecord storage requires the active_record gem: #{e.message}"
      end

      def handle_exceeded(monthly_total:, last_event: nil)
        config = LlmCostTracker.configuration
        payload = {
          monthly_total: monthly_total,
          budget: config.monthly_budget,
          last_event: last_event
        }

        config.on_budget_exceeded&.call(payload)
        raise BudgetExceededError.new(**payload) if raise_on_exceeded?(config)
      end

      def raise_on_exceeded?(config)
        %i[raise block_requests].include?(config.budget_exceeded_behavior)
      end
    end
  end
end
