# frozen_string_literal: true

require_relative "logging"

module LlmCostTracker
  class Budget
    class << self
      def enforce!
        config = LlmCostTracker.configuration
        return unless config.budget_exceeded_behavior == :block_requests
        return unless config.active_record?

        enforce_period_budget(:monthly, config.monthly_budget)
        enforce_period_budget(:daily, config.daily_budget)
      end

      def check!(event)
        config = LlmCostTracker.configuration
        return unless event.cost

        check_per_call_budget(event, config)
        check_period_budget(event, config, :daily, config.daily_budget)
        check_period_budget(event, config, :monthly, config.monthly_budget)
      end

      private

      def enforce_period_budget(period, budget)
        return unless budget

        total = active_record_total(period, time: Time.now.utc)
        return unless total >= budget

        handle_exceeded(budget_type: period, total: total, budget: budget)
      end

      def check_per_call_budget(event, config)
        budget = config.per_call_budget
        return unless budget

        call_cost = event.cost.total_cost
        return unless call_cost >= budget

        handle_exceeded(budget_type: :per_call, total: call_cost, budget: budget, last_event: event)
      end

      def check_period_budget(event, config, period, budget)
        return unless budget

        total = if config.active_record?
                  active_record_total(period, time: event.tracked_at)
                else
                  event.cost.total_cost
                end
        return unless total >= budget

        handle_exceeded(budget_type: period, total: total, budget: budget, last_event: event)
      end

      def active_record_total(period, time:)
        case period
        when :monthly then active_record_monthly_total(time: time)
        when :daily   then active_record_daily_total(time: time)
        end
      end

      def active_record_monthly_total(time: Time.now.utc)
        require_relative "llm_api_call" unless defined?(LlmCostTracker::LlmApiCall)
        require_relative "storage/active_record_store" unless defined?(LlmCostTracker::Storage::ActiveRecordStore)

        LlmCostTracker::Storage::ActiveRecordStore.monthly_total(time: time)
      rescue LoadError => e
        raise Error, "ActiveRecord storage requires the active_record gem: #{e.message}"
      end

      def active_record_daily_total(time: Time.now.utc)
        require_relative "llm_api_call" unless defined?(LlmCostTracker::LlmApiCall)
        require_relative "storage/active_record_store" unless defined?(LlmCostTracker::Storage::ActiveRecordStore)

        LlmCostTracker::Storage::ActiveRecordStore.daily_total(time: time)
      rescue LoadError => e
        raise Error, "ActiveRecord storage requires the active_record gem: #{e.message}"
      end

      def handle_exceeded(budget_type:, total:, budget:, last_event: nil)
        config = LlmCostTracker.configuration
        payload = budget_payload(
          budget_type: budget_type,
          total: total,
          budget: budget,
          last_event: last_event
        )

        if notify_exceeded?(config, budget_type: budget_type, total: total, budget: budget, last_event: last_event)
          config.on_budget_exceeded&.call(payload)
        end
        raise BudgetExceededError.new(**payload) if raise_on_exceeded?(config)
      end

      def budget_payload(budget_type:, total:, budget:, last_event:)
        payload = {
          budget_type: budget_type,
          total: total,
          budget: budget,
          last_event: last_event
        }
        payload[:monthly_total] = total if budget_type == :monthly
        payload[:daily_total] = total if budget_type == :daily
        payload[:call_cost] = total if budget_type == :per_call
        payload
      end

      def notify_exceeded?(config, budget_type:, total:, budget:, last_event:)
        return false unless config.on_budget_exceeded
        return true unless config.budget_exceeded_behavior == :notify
        return true unless last_event&.cost
        return true if budget_type == :per_call

        total - last_event.cost.total_cost < budget
      end

      def raise_on_exceeded?(config)
        %i[raise block_requests].include?(config.budget_exceeded_behavior)
      end
    end
  end
end
