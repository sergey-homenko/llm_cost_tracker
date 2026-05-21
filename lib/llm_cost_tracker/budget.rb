# frozen_string_literal: true

require "bigdecimal"

require_relative "logging"
require_relative "ledger"
require_relative "pricing/estimator"

module LlmCostTracker
  class Budget
    BUDGET_TYPE_TO_PERIOD = { monthly: :month, daily: :day }.freeze

    class << self
      def enforce!(provider: nil, model: nil, request: nil)
        config = LlmCostTracker.configuration
        return unless config.budget_exceeded_behavior == :block_requests

        estimate = estimate_cost(provider: provider, model: model, request: request)
        raise_per_call_pre_send(estimate, config.per_call_budget) if config.per_call_budget && estimate.positive?

        budgets = { monthly: config.monthly_budget, daily: config.daily_budget }.compact
        return if budgets.empty?

        totals = totals_for(budgets.keys, time: Time.now.utc)

        budgets.each do |budget_type, budget|
          total = totals.fetch(budget_type) + estimate
          next unless total >= budget

          raise BudgetExceededError.new(**budget_payload(
            budget_type: budget_type, total: total, budget: budget, last_event: nil, stage: :pre_send
          ))
        end
      end

      def check!(event)
        config = LlmCostTracker.configuration
        return unless event.total_cost

        check_per_call_budget(event, config)
        budgets = { daily: config.daily_budget, monthly: config.monthly_budget }.compact
        totals = totals_for(budgets.keys, time: event.tracked_at)

        budgets.each do |budget_type, budget|
          total = totals.fetch(budget_type)

          handle_exceeded(budget_type: budget_type, total: total, budget: budget, last_event: event) if total >= budget
        end
      end

      private

      def estimate_cost(provider:, model:, request:)
        return BigDecimal("0") unless provider && model && request

        Pricing::Estimator.call(provider: provider, model: model, request: request) || BigDecimal("0")
      end

      def raise_per_call_pre_send(estimate, budget)
        return unless estimate >= budget

        raise BudgetExceededError.new(**budget_payload(
          budget_type: :per_call, total: estimate, budget: budget, last_event: nil, stage: :pre_send
        ))
      end

      def check_per_call_budget(event, config)
        budget = config.per_call_budget
        return unless budget

        total = event.total_cost
        return unless total >= budget

        handle_exceeded(budget_type: :per_call, total: total, budget: budget, last_event: event)
      end

      def totals_for(budget_types, time:)
        return {} if budget_types.empty?

        periods = budget_types.map { |type| BUDGET_TYPE_TO_PERIOD.fetch(type) }
        period_totals = LlmCostTracker::Ledger::Period::Totals.call(periods, time: time)
        BUDGET_TYPE_TO_PERIOD.each_with_object({}) do |(budget_type, period), totals|
          totals[budget_type] = period_totals[period] if period_totals.key?(period)
        end
      end

      def handle_exceeded(budget_type:, total:, budget:, last_event: nil)
        config = LlmCostTracker.configuration
        payload = budget_payload(
          budget_type: budget_type,
          total: total,
          budget: budget,
          last_event: last_event,
          stage: :post_spend
        )

        if notify_exceeded?(config, budget_type: budget_type, total: total, budget: budget, last_event: last_event)
          config.on_budget_exceeded&.call(payload)
        end
        raise BudgetExceededError.new(**payload) if %i[raise block_requests].include?(config.budget_exceeded_behavior)
      end

      def budget_payload(budget_type:, total:, budget:, last_event:, stage:)
        {
          budget_type: budget_type,
          total: total,
          budget: budget,
          last_event: last_event,
          stage: stage
        }
      end

      def notify_exceeded?(config, budget_type:, total:, budget:, last_event:)
        return false unless config.on_budget_exceeded
        return true if !last_event&.total_cost || budget_type == :per_call

        total - last_event.total_cost < budget
      end
    end
  end
end
