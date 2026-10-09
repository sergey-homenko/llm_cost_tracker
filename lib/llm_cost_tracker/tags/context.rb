# frozen_string_literal: true

require "active_support/isolated_execution_state"

module LlmCostTracker
  module Tags
    module Context
      KEY = :llm_cost_tracker_tags

      class << self
        def with(tags)
          stack = Fiber[KEY] || []
          scope = [Thread.current, Sanitizer.call((tags || {}).to_h)]
          shared = scope.dup
          Fiber[KEY] = stack + [scope]
          ActiveSupport::IsolatedExecutionState[KEY] = shared_scopes + [shared]
          yield
        ensure
          scope&.clear
          Fiber[KEY] = stack
          ActiveSupport::IsolatedExecutionState[KEY] = shared_scopes.reject { |entry| entry.equal?(shared) } if shared
        end

        def tags
          config = LlmCostTracker.configuration
          base = config.tags.static_sanitized_default || Sanitizer.call(call_default_tags(config.tags.default))
          base.merge(scoped)
        end

        def scoped
          current = Thread.current
          shared = shared_scopes.reject { |owner, _| owner.equal?(current) }
          own = Array(Fiber[KEY]).select { |owner, _| owner.equal?(current) }
          (shared + own).each_with_object({}) { |(_, tags), merged| merged.merge!(tags) }
        end

        def call_default_tags(proc_or_lambda)
          (proc_or_lambda.call || {}).to_h
        rescue StandardError => e
          Logging.warn("LlmCostTracker tags.default proc raised: #{e.class}: #{e.message}; using empty default tags")
          {}
        end

        private

        def shared_scopes = Array(ActiveSupport::IsolatedExecutionState[KEY])
      end
    end
  end
end
