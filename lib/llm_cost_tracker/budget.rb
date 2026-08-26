# frozen_string_literal: true

require "bigdecimal"

require_relative "ledger"
require_relative "pricing/estimator"
require_relative "budget/per_tag"
require_relative "tags/context"

module LlmCostTracker
  module Budget
    BUDGET_TYPE_TO_PERIOD = { monthly: :month, daily: :day }.freeze

    class << self
      def enforce!(provider: nil, model: nil, request: nil, estimate: nil, tags: nil, force: false)
        config = LlmCostTracker.configuration
        return unless config.enabled

        globally = force || config.budgets.exceeded_behavior == :block_requests
        per_tag = force || PerTag.blocking?
        return unless globally || per_tag

        estimate ||= estimate_cost(provider: provider, model: model, request: request)
        now = Time.now.utc
        enforce_globally(config, estimate: estimate, time: now) if globally
        return unless per_tag

        check_per_tag(tags || Tags::Context.tags,
                      time: now,
                      estimate: estimate,
                      blocking_only: !force) do |rule, window, total, limit|
          raise_pre_send(budget_type: window, total: total, budget: limit, scope: scope_for(rule))
        end
      end

      def check!(event, behavior_override: nil)
        config = LlmCostTracker.configuration
        return unless event.total_cost

        check_per_call_budget(event, config, behavior_override)
        check_windowed({ daily: config.budgets.daily, monthly: config.budgets.monthly }.compact,
                       time: event.tracked_at) do |budget_type, total, budget|
          handle_exceeded(budget_type: budget_type,
                          total: total,
                          budget: budget,
                          previous_total: total - event.total_cost,
                          last_event: event,
                          behavior: behavior_override)
        end
      end

      def check_persisted!(events, behavior_override: nil)
        by_rule = PerTag.rules_for_events(events.select(&:total_cost))
        by_rule = by_rule.reject { |rule, _| rule.on_exceeded.nil? } if behavior_override == :notify
        window_buckets(by_rule).each do |(key, window, bucket), scored|
          totals = PerTag.spend_by_value(key, scored.keys.map(&:value), window, bucket)
          scored.each do |rule, recorded|
            total = totals.fetch(rule.value, 0).to_d
            limit = rule.windows.fetch(window)
            next if total < limit

            handle_exceeded(
              budget_type: window,
              total: total,
              budget: limit,
              previous_total: total - recorded.sum(&:total_cost),
              last_event: recorded.last,
              scope: scope_for(rule),
              behavior: behavior_override || rule.behavior,
              on_exceeded: rule.on_exceeded
            )
          end
        end
      end

      def notify_persisted_safely!(events)
        check_persisted!(events, behavior_override: :notify)
      rescue StandardError => e
        Logging.warn("Per-tag budget check failed after ingest: #{e.class}: #{e.message}")
      end

      private

      def window_buckets(by_rule)
        by_rule.each_with_object({}) do |(rule, events), grouped|
          rule.windows.each_key do |window|
            events.group_by { |event| PerTag.window_start(window, event.tracked_at) }
                  .each do |bucket, bucket_events|
              (grouped[[rule.key, window, bucket]] ||= {})[rule] = bucket_events
            end
          end
        end
      end

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

      def check_per_call_budget(event, config, behavior_override)
        budget = config.budgets.per_call
        return unless budget

        total = event.total_cost
        return unless total >= budget

        handle_exceeded(budget_type: :per_call,
                        total: total,
                        budget: budget,
                        previous_total: nil,
                        last_event: event,
                        behavior: behavior_override)
      end

      def enforce_globally(config, estimate:, time:)
        raise_per_call_pre_send(estimate, config.budgets.per_call) if config.budgets.per_call && estimate.positive?

        check_windowed({ monthly: config.budgets.monthly, daily: config.budgets.daily }.compact,
                       time: time,
                       estimate: estimate) do |budget_type, total, budget|
          raise_pre_send(budget_type: budget_type, total: total, budget: budget)
        end
      end

      def raise_pre_send(budget_type:, total:, budget:, scope: nil)
        raise BudgetExceededError.new(**budget_payload(
          budget_type: budget_type, total: total, budget: budget, last_event: nil, stage: :pre_send, scope: scope
        ))
      end

      def check_per_tag(tags, time:, estimate: BigDecimal("0"), blocking_only: false)
        PerTag.rules_for(tags, blocking_only: blocking_only).each do |rule|
          rule.windows.each do |window, limit|
            total = PerTag.spend(rule.key, rule.value, window, time: time) + estimate
            yield(rule, window, total, limit) if total >= limit
          end
        end
      end

      def scope_for(rule)
        { key: rule.key, value: rule.value }
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

      def handle_exceeded(budget_type:,
                          total:,
                          budget:,
                          previous_total:,
                          last_event: nil,
                          scope: nil,
                          behavior: nil,
                          on_exceeded: nil)
        config = LlmCostTracker.configuration
        behavior ||= config.budgets.exceeded_behavior
        on_exceeded ||= config.budgets.on_exceeded
        payload = budget_payload(
          budget_type: budget_type,
          total: total,
          budget: budget,
          last_event: last_event,
          stage: :post_spend,
          scope: scope
        )

        on_exceeded.call(payload) if on_exceeded && (previous_total.nil? || previous_total < budget)
        raise BudgetExceededError.new(**payload) if %i[raise block_requests].include?(behavior)
      end

      def budget_payload(budget_type:, total:, budget:, last_event:, stage:, scope: nil)
        {
          budget_type: budget_type,
          total: total,
          budget: budget,
          last_event: last_event,
          stage: stage,
          scope: scope
        }
      end
    end
  end
end
