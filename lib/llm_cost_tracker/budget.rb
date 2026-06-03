# frozen_string_literal: true

require "bigdecimal"

require_relative "ledger"
require_relative "pricing/estimator"

module LlmCostTracker
  module Budget
    BUDGET_TYPE_TO_PERIOD = { monthly: :month, daily: :day }.freeze

    class << self
      def enforce!(provider: nil, model: nil, request: nil, estimate: nil, force: false)
        config = LlmCostTracker.configuration
        return unless config.enabled
        return unless force || config.budget_exceeded_behavior == :block_requests

        estimate ||= estimate_cost(provider: provider, model: model, request: request)
        raise_per_call_pre_send(estimate, config.per_call_budget) if config.per_call_budget && estimate.positive?

        check_windowed({ monthly: config.monthly_budget, daily: config.daily_budget }.compact,
                       time: Time.now.utc,
estimate: estimate) do |budget_type, total, budget|
          raise BudgetExceededError.new(**budget_payload(
            budget_type: budget_type, total: total, budget: budget, last_event: nil, stage: :pre_send
          ))
        end
      end

      def check!(event)
        config = LlmCostTracker.configuration
        return unless event.total_cost

        check_per_call_budget(event, config)
        check_windowed({ daily: config.daily_budget, monthly: config.monthly_budget }.compact,
                       time: event.tracked_at) do |budget_type, total, budget|
          handle_exceeded(budget_type: budget_type, total: total, budget: budget, last_event: event)
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

      def check_windowed(budgets, time:, estimate: BigDecimal("0"))
        return if budgets.empty?

        totals = totals_for(budgets.keys, time: time)
        budgets.each do |budget_type, budget|
          total = totals.fetch(budget_type) + estimate
          yield(budget_type, total, budget) if total >= budget
        end
      end

      def totals_for(budget_types, time:)
        return {} if budget_types.empty?

        period_for = budget_types.to_h { |type| [type, BUDGET_TYPE_TO_PERIOD.fetch(type)] }
        period_totals = LlmCostTracker::Ledger::Period::Totals.call(period_for.values, time: time)
        period_for.transform_values { |period| period_totals.fetch(period) }
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
