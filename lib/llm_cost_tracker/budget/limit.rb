# frozen_string_literal: true

require "bigdecimal"

module LlmCostTracker
  module Budget
    Limit = Data.define(:budget_type, :budget, :scope, :behavior, :on_exceeded) do
      def self.global(budget_type, budget)
        new(budget_type: budget_type, budget: budget, scope: nil, behavior: nil, on_exceeded: nil)
      end

      def over?(total)
        budget_type == :calls ? total > budget : total >= budget
      end

      def charge(cost)
        budget_type == :calls ? 1 : cost
      end

      def counts?(event)
        budget_type == :calls || !event.total_cost.nil?
      end

      def amount_in_window(changes, time)
        start = PerTag.window_start(budget_type, time)
        changes.sum(BigDecimal("0")) { |change| start.nil? || change.tracked_at >= start ? change.total_cost : 0 }
      end

      def block!(total)
        raise BudgetExceededError.new(
          budget_type: budget_type, total: total, budget: budget, stage: :pre_send, scope: scope
        )
      end

      def handle_exceeded(total:, previous_total:, last_event: nil, behavior_override: nil)
        budgets = LlmCostTracker.configuration.budgets
        raising = %i[raise block_requests].include?(behavior_override || behavior || budgets.exceeded_behavior)
        callback = on_exceeded || budgets.on_exceeded
        payload = {
          budget_type: budget_type,
          total: total,
          budget: budget,
          last_event: last_event,
          stage: :post_spend,
          scope: scope
        }
        callback.call(payload) if callback && (previous_total.nil? || !over?(previous_total))
        BudgetExceededError.new(**payload) if raising
      end
    end
  end
end
