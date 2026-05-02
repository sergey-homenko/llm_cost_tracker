# frozen_string_literal: true

require_relative "logging"
require_relative "ledger"

module LlmCostTracker
  class Budget
    class << self
      def enforce!
        config = LlmCostTracker.configuration
        return unless config.budget_exceeded_behavior == :block_requests

        budgets = { monthly: config.monthly_budget, daily: config.daily_budget }.compact
        return if budgets.empty?

        totals = LlmCostTracker::Ledger::Period::Totals.call(budgets.keys, time: Time.now.utc)

        budgets.each do |period, budget|
          total = totals.fetch(period)

          handle_exceeded(budget_type: period, total: total, budget: budget) if total >= budget
        end
      end

      def check!(event)
        config = LlmCostTracker.configuration
        return unless event.total_cost

        check_per_call_budget(event, config)
        budgets = { daily: config.daily_budget, monthly: config.monthly_budget }.compact
        totals = totals_for_check(event, budgets)

        budgets.each do |period, budget|
          total = totals.fetch(period)

          handle_exceeded(budget_type: period, total: total, budget: budget, last_event: event) if total >= budget
        end
      end

      private

      def check_per_call_budget(event, config)
        budget = config.per_call_budget
        return unless budget

        total = event.total_cost
        return unless total >= budget

        handle_exceeded(budget_type: :per_call, total: total, budget: budget, last_event: event)
      end

      def totals_for_check(event, budgets)
        return {} if budgets.empty?

        LlmCostTracker::Ledger::Period::Totals.call(budgets.keys, time: event.tracked_at)
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
        raise BudgetExceededError.new(**payload) if %i[raise block_requests].include?(config.budget_exceeded_behavior)
      end

      def budget_payload(budget_type:, total:, budget:, last_event:)
        {
          budget_type: budget_type,
          total: total,
          budget: budget,
          last_event: last_event
        }
      end

      def notify_exceeded?(config, budget_type:, total:, budget:, last_event:)
        return false unless config.on_budget_exceeded
        return true unless config.budget_exceeded_behavior == :notify
        return true unless last_event&.total_cost
        return true if budget_type == :per_call

        total - last_event.total_cost < budget
      end
    end
  end
end
