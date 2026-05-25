# frozen_string_literal: true

require "active_support/isolated_execution_state"

module LlmCostTracker
  module Tags
    module Context
      KEY = :llm_cost_tracker_tags

      class << self
        def with(tags)
          stack = ActiveSupport::IsolatedExecutionState[KEY] || []
          ActiveSupport::IsolatedExecutionState[KEY] = stack + [Sanitizer.call((tags || {}).to_h)]
          yield
        ensure
          ActiveSupport::IsolatedExecutionState[KEY] = stack
        end

        def tags
          config = LlmCostTracker.configuration
          base = config.static_sanitized_default_tags ||
                 Sanitizer.call(call_default_tags(config.default_tags).to_h)
          base.merge(*Array(ActiveSupport::IsolatedExecutionState[KEY]))
        end

        def call_default_tags(proc_or_lambda)
          proc_or_lambda.call
        rescue StandardError => e
          Logging.warn("LlmCostTracker default_tags proc raised: #{e.class}: #{e.message}; using empty default tags")
          {}
        end

        def clear!
          ActiveSupport::IsolatedExecutionState[KEY] = []
        end
      end
    end
  end
end
