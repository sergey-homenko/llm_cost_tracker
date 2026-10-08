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

        estimates = estimate ? [estimate] : request_estimates(provider: provider, model: model, request: request)
        estimate = estimates.sum(BigDecimal("0"))
        now = Time.now.utc
        enforce_globally(config, estimate: estimate, largest: estimates.max || estimate, time: now) if globally
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
        errors = []
        if event.total_cost
          errors << check_per_call_budget(event, config, behavior_override)
          check_windowed({ daily: config.budgets.daily, monthly: config.budgets.monthly }.compact,
                         time: event.tracked_at) do |budget_type, total, budget|
            errors << handle_exceeded(budget_type: budget_type,
                                      total: total,
                                      budget: budget,
                                      previous_total: total - event.total_cost,
                                      last_event: event,
                                      behavior: behavior_override)
          end
        end
        errors.concat(persisted_errors([event], behavior_override)) unless Ingestion.async?
        raise_first(errors)
      end

      def check_persisted!(events, behavior_override: nil)
        raise_first(persisted_errors(events, behavior_override))
      end

      def notify_persisted_safely!(events)
        check_persisted!(events, behavior_override: :notify)
      rescue StandardError => e
        Logging.warn("Per-tag budget check failed after ingest: #{e.class}: #{e.message}")
      end

      def notify_repriced_safely!(changes)
        return if changes.empty?

        now = Time.now.utc
        budgets = LlmCostTracker.configuration.budgets
        check_windowed({ daily: budgets.daily, monthly: budgets.monthly }.compact, time: now) do |type, total, budget|
          handle_exceeded(budget_type: type,
                          total: total,
                          budget: budget,
                          previous_total: total - current_amount(changes, type, now),
                          behavior: :notify)
        end
        PerTag.rules_for_events(changes).each do |rule, repriced|
          rule.windows.except(:calls).each do |window, limit|
            amount = current_amount(repriced, window, now)
            total = PerTag.spend(rule.key, rule.value, window, time: now) if rule.on_exceeded && amount.positive?
            next unless total && over?(window, total, limit)

            handle_exceeded(budget_type: window,
                            total: total,
                            budget: limit,
                            previous_total: total - amount,
                            scope: scope_for(rule),
                            behavior: :notify,
                            on_exceeded: rule.on_exceeded)
          end
        end
      rescue StandardError => e
        Logging.warn("Budget check failed after repricing: #{e.class}: #{e.message}")
      end

      private

      def persisted_errors(events, behavior_override)
        by_rule = PerTag.rules_for_events(events)
        by_rule = by_rule.reject { |rule, _| rule.on_exceeded.nil? } if behavior_override == :notify
        window_buckets(by_rule).flat_map do |(key, window, bucket), scored|
          upto = scored.values.flatten.map(&:tracked_at).max unless Ingestion.async?
          totals = PerTag.spend_by_value(key, scored.keys.map(&:value), window, bucket, upto)
          scored.filter_map do |rule, recorded|
            total, upto_total = totals.fetch(rule.value, [0, 0])
            limit = rule.windows.fetch(window)
            next unless over?(window, total, limit)

            handle_exceeded(
              budget_type: window,
              total: total,
              budget: limit,
              previous_total: (over?(window, upto_total, limit) ? upto_total : total) -
                              recorded.sum { |event| amount(window, event) },
              last_event: recorded.last,
              scope: scope_for(rule),
              behavior: behavior_override || rule.behavior,
              on_exceeded: rule.on_exceeded
            )
          end
        end
      end

      def raise_first(errors)
        error = errors.compact.first
        raise error if error
      end

      def window_buckets(by_rule)
        by_rule.each_with_object({}) do |(rule, events), grouped|
          rule.windows.each_key do |window|
            events.select { |event| amount(window, event) }
                  .group_by { |event| PerTag.window_start(window, event.tracked_at) }
                  .each do |bucket, bucket_events|
              (grouped[[rule.key, window, bucket]] ||= {})[rule] = bucket_events
            end
          end
        end
      end

      def amount(window, event)
        window == :calls ? 1 : event.total_cost
      end

      def over?(budget_type, total, budget)
        budget_type == :calls ? total > budget : total >= budget
      end

      def current_amount(changes, window, now)
        start = PerTag.window_start(window, now)
        changes.sum(BigDecimal("0")) { |change| start.nil? || change.tracked_at >= start ? change.total_cost : 0 }
      end

      def request_estimates(provider:, model:, request:)
        batch = request["requests"] if request && !model
        return [estimate_cost(provider: provider, model: model, request: request)] unless batch.is_a?(Array)

        batch.map do |entry|
          params = entry["params"] if entry.is_a?(Hash)
          params.is_a?(Hash) ? estimate_cost(provider: provider, model: params["model"], request: params) : 0
        end
      end

      def estimate_cost(provider:, model:, request:)
        return BigDecimal("0") unless provider && model && request

        Pricing::Estimator.call(provider: provider, model: model, request: request) || BigDecimal("0")
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

      def enforce_globally(config, estimate:, largest:, time:)
        per_call = config.budgets.per_call
        if per_call && largest.positive? && largest >= per_call
          raise_pre_send(budget_type: :per_call, total: largest, budget: per_call)
        end

        check_windowed({ monthly: config.budgets.monthly, daily: config.budgets.daily }.compact,
                       time: time,
                       estimate: estimate) do |budget_type, total, budget|
          raise_pre_send(budget_type: budget_type, total: total, budget: budget)
        end
      end

      def raise_pre_send(budget_type:, total:, budget:, scope: nil)
        raise BudgetExceededError.new(
          budget_type: budget_type, total: total, budget: budget, stage: :pre_send, scope: scope
        )
      end

      def check_per_tag(tags, time:, estimate: BigDecimal("0"), blocking_only: false)
        PerTag.rules_for(tags, blocking_only: blocking_only).each do |rule|
          rule.windows.each do |window, limit|
            total = PerTag.spend(rule.key, rule.value, window, time: time) + (window == :calls ? 1 : estimate)
            yield(rule, window, total, limit) if over?(window, total, limit)
          end
        end
      end

      def scope_for(rule)
        { key: rule.key, value: rule.value }
      end

      def check_windowed(budgets, time:, estimate: BigDecimal("0"))
        return if budgets.empty?

        periods = budgets.keys.map { |type| BUDGET_TYPE_TO_PERIOD.fetch(type) }
        totals = LlmCostTracker::Ledger::Period::Totals.call(periods, time: time)
        budgets.each do |budget_type, budget|
          total = totals.fetch(BUDGET_TYPE_TO_PERIOD.fetch(budget_type)) + estimate
          yield(budget_type, total, budget) if total >= budget
        end
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
        payload = {
          budget_type: budget_type,
          total: total,
          budget: budget,
          last_event: last_event,
          stage: :post_spend,
          scope: scope
        }

        on_exceeded.call(payload) if on_exceeded && (previous_total.nil? || !over?(budget_type, previous_total, budget))
        BudgetExceededError.new(**payload) if %i[raise block_requests].include?(behavior)
      end
    end
  end
end
