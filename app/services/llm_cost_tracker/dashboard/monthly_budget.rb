# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    class MonthlyBudget
      def self.status
        budget = LlmCostTracker.configuration.budgets.monthly
        return nil unless budget

        new(budget.to_f, Time.now.utc).status
      end

      def initialize(budget, now)
        @budget = budget
        @now = now
        @spent = LlmCostTracker::Ledger::Period::Totals.call(%i[month], time: now).fetch(:month)
        @projected_spent = project(@spent)
      end

      def status
        {
          budget: budget,
          spent: spent,
          percent_used: percent_used,
          projected_spent: projected_spent,
          projected_percent_used: projected_percent_used,
          projected_delta: projected_delta,
          projection_end_label: now.end_of_month.strftime("%b %-d"),
          fill_modifier: fill_modifier,
          progress_percent: percent_used.clamp(0.0, 100.0),
          projected_marker_percent: projected_percent_used.clamp(0.0, 100.0),
          **projected_delta_labels
        }
      end

      private

      attr_reader :budget, :now, :spent, :projected_spent

      def project(amount)
        month_start = now.beginning_of_month
        elapsed_seconds = now - month_start
        return amount if amount.zero? || !elapsed_seconds.positive?

        amount * ((now.end_of_month - month_start) / elapsed_seconds)
      end

      def percent_used
        share_of_budget(spent)
      end

      def projected_percent_used
        share_of_budget(projected_spent)
      end

      def share_of_budget(amount)
        budget.positive? ? (amount / budget) * 100.0 : 0.0
      end

      def projected_delta
        projected_spent - budget
      end

      def fill_modifier
        return "lct-budget-fill--over" if percent_used >= 100.0
        return "lct-budget-fill--warn" if percent_used >= 80.0

        ""
      end

      def projected_delta_labels
        direction = projected_delta.positive? ? "over" : "under"
        {
          projected_delta_amount: projected_delta.abs,
          projected_delta_direction: direction,
          projected_delta_status_class: "lct-budget-projection-status--#{direction}"
        }
      end
    end
  end
end
