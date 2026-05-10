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
          default_tags = LlmCostTracker.configuration.default_tags
          default_tags = default_tags.call if default_tags.respond_to?(:call)

          Sanitizer.call(default_tags.to_h).merge(*Array(ActiveSupport::IsolatedExecutionState[KEY]))
        end

        def clear!
          ActiveSupport::IsolatedExecutionState[KEY] = []
        end
      end
    end
  end
end
