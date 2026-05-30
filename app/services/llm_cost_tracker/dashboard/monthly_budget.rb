# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    module MonthlyBudget
      module_function

      def status
        budget = LlmCostTracker.configuration.monthly_budget
        return nil unless budget

        budget = budget.to_f
        now = Time.now.utc
        month_start = now.beginning_of_month
        month_end = now.end_of_month
        spent = LlmCostTracker::Ledger::Period::Totals.call(%i[month], time: now).fetch(:month)
        elapsed_seconds = now - month_start
        total_seconds = month_end - month_start
        projected_spent = if spent.zero? || !elapsed_seconds.positive?
                            spent
                          else
                            spent * (total_seconds / elapsed_seconds)
                          end
        percent_used = budget.positive? ? (spent / budget) * 100.0 : 0.0
        projected_percent_used = budget.positive? ? (projected_spent / budget) * 100.0 : 0.0
        projected_delta = projected_spent - budget

        {
          budget: budget,
          spent: spent,
          percent_used: percent_used,
          projected_spent: projected_spent,
          projected_percent_used: projected_percent_used,
          projected_delta: projected_delta,
          projection_end_label: month_end.strftime("%b %-d"),
          fill_modifier: fill_modifier(percent_used),
          progress_percent: clamped_percent(percent_used),
          projected_marker_percent: clamped_percent(projected_percent_used),
          projected_delta_amount: projected_delta.abs,
          projected_delta_direction: projected_delta.positive? ? "over" : "under",
          projected_delta_status_class: projected_delta_status_class(projected_delta)
        }
      end

      def clamped_percent(value)
        value.clamp(0.0, 100.0)
      end

      def fill_modifier(percent)
        return "lct-budget-fill--over" if percent >= 100.0
        return "lct-budget-fill--warn" if percent >= 80.0

        ""
      end

      def projected_delta_status_class(delta)
        return "lct-budget-projection-status--over" if delta.positive?

        "lct-budget-projection-status--under"
      end
    end
  end
end
