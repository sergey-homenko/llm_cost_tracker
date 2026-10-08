# frozen_string_literal: true

require "bigdecimal"

require_relative "limit"
require_relative "../ledger"

module LlmCostTracker
  module Budget
    module Global
      PERIODS = { monthly: :month, daily: :day }.freeze

      class << self
        def enforce!(estimate, time:)
          budgets = LlmCostTracker.configuration.budgets
          per_call = budgets.per_call
          largest = estimate.largest
          Limit.global(:per_call, per_call).block!(largest) if per_call && largest.positive? && largest >= per_call

          windows = { monthly: budgets.monthly, daily: budgets.daily }
          each_exceeded(windows, time: time, estimate: estimate.total) { |limit, total| limit.block!(total) }
        end

        def post_spend_errors(event, behavior_override)
          budgets = LlmCostTracker.configuration.budgets
          errors = [per_call_error(event, budgets.per_call, behavior_override)]
          each_exceeded({ daily: budgets.daily, monthly: budgets.monthly }, time: event.tracked_at) do |limit, total|
            errors << limit.handle_exceeded(total: total,
                                            previous_total: total - event.total_cost,
                                            last_event: event,
                                            behavior_override: behavior_override)
          end
          errors
        end

        def notify_repriced(changes, time:)
          budgets = LlmCostTracker.configuration.budgets
          each_exceeded({ daily: budgets.daily, monthly: budgets.monthly }, time: time) do |limit, total|
            limit.handle_exceeded(total: total,
                                  previous_total: total - limit.amount_in_window(changes, time),
                                  behavior_override: :notify)
          end
        end

        private

        def per_call_error(event, per_call, behavior_override)
          total = event.total_cost
          return unless per_call && total >= per_call

          Limit.global(:per_call, per_call).handle_exceeded(
            total: total, previous_total: nil, last_event: event, behavior_override: behavior_override
          )
        end

        def each_exceeded(windows, time:, estimate: BigDecimal("0"))
          windows = windows.compact
          return if windows.empty?

          totals = Ledger::Period::Totals.call(windows.keys.map { |type| PERIODS.fetch(type) }, time: time)
          windows.each do |type, budget|
            total = totals.fetch(PERIODS.fetch(type)) + estimate
            yield Limit.global(type, budget), total if total >= budget
          end
        end
      end
    end
  end
end
