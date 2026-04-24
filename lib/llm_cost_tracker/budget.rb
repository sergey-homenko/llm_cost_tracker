# frozen_string_literal: true

require_relative "logging"

module LlmCostTracker
  class Budget
    class << self
      def enforce!
        config = LlmCostTracker.configuration
        return unless config.budget_exceeded_behavior == :block_requests
        return unless config.active_record?

        budgets = enforce_period_budgets(config)
        return if budgets.empty?

        totals = active_record_totals(budgets.keys, time: Time.now.utc)

        budgets.each do |period, budget|
          total = totals.fetch(period)

          handle_exceeded(budget_type: period, total: total, budget: budget) if total >= budget
        end
      end

      def check!(event)
        config = LlmCostTracker.configuration
        return unless event.cost

        check_per_call_budget(event, config)
        budgets = check_period_budgets(config)
        totals = totals_for_check(event, config, budgets)

        budgets.each do |period, budget|
          total = totals.fetch(period)

          handle_exceeded(budget_type: period, total: total, budget: budget, last_event: event) if total >= budget
        end
      end

      private

      def check_per_call_budget(event, config)
        budget = config.per_call_budget
        return unless budget

        call_cost = event.cost.total_cost
        return unless call_cost >= budget

        handle_exceeded(budget_type: :per_call, total: call_cost, budget: budget, last_event: event)
      end

      def enforce_period_budgets(config)
        {
          monthly: config.monthly_budget,
          daily: config.daily_budget
        }.compact
      end

      def check_period_budgets(config)
        {
          daily: config.daily_budget,
          monthly: config.monthly_budget
        }.compact
      end

      def totals_for_check(event, config, budgets)
        return {} if budgets.empty?
        return active_record_totals(budgets.keys, time: event.tracked_at) if config.active_record?

        budgets.to_h { |period, _budget| [period, event.cost.total_cost] }
      end

      def active_record_totals(periods, time:)
        require_relative "llm_api_call" unless defined?(LlmCostTracker::LlmApiCall)
        require_relative "storage/active_record_store" unless defined?(LlmCostTracker::Storage::ActiveRecordStore)

        LlmCostTracker::Storage::ActiveRecordStore.period_totals(periods, time: time)
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
