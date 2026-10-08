# frozen_string_literal: true

require_relative "budget/estimate"
require_relative "budget/global"
require_relative "budget/tagged"

module LlmCostTracker
  module Budget
    class << self
      def enforce!(provider: nil, model: nil, request: nil, tags: nil, force: false)
        config = LlmCostTracker.configuration
        return unless config.enabled

        globally = force || config.budgets.exceeded_behavior == :block_requests
        per_tag = force || PerTag.blocking?
        return unless globally || per_tag

        estimate = Estimate.for(provider: provider, model: model, request: request)
        now = Time.now.utc
        Global.enforce!(estimate, time: now) if globally
        Tagged.enforce!(tags, estimate.total, time: now, blocking_only: !force) if per_tag
      end

      def check!(event, behavior_override: nil)
        errors = event.total_cost ? Global.post_spend_errors(event, behavior_override) : []
        errors.concat(Tagged.post_spend_errors([event], behavior_override)) unless Ingestion.async?
        raise_first(errors)
      end

      def check_persisted!(events, behavior_override: nil)
        raise_first(Tagged.post_spend_errors(events, behavior_override))
      end

      def notify_persisted_safely!(events)
        check_persisted!(events, behavior_override: :notify)
      rescue StandardError => e
        Logging.warn("Per-tag budget check failed after ingest: #{e.class}: #{e.message}")
      end

      def notify_repriced_safely!(changes)
        return if changes.empty?

        now = Time.now.utc
        Global.notify_repriced(changes, time: now)
        Tagged.notify_repriced(changes, time: now)
      rescue StandardError => e
        Logging.warn("Budget check failed after repricing: #{e.class}: #{e.message}")
      end

      private

      def raise_first(errors)
        error = errors.compact.first
        raise error if error
      end
    end
  end
end
