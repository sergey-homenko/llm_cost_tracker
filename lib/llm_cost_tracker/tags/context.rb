# frozen_string_literal: true

require "active_support/core_ext/object/deep_dup"
require "active_support/isolated_execution_state"

module LlmCostTracker
  module Tags
    module Context
      KEY = :llm_cost_tracker_tags

      class << self
        def with(tags)
          stack = ActiveSupport::IsolatedExecutionState[KEY] || []
          ActiveSupport::IsolatedExecutionState[KEY] = stack + [scrub((tags || {}).to_h)]
          yield
        ensure
          ActiveSupport::IsolatedExecutionState[KEY] = stack
        end

        def tags
          default_tags = LlmCostTracker.configuration.default_tags
          default_tags = default_tags.call if default_tags.respond_to?(:call)

          scrub(default_tags.to_h).merge(*Array(ActiveSupport::IsolatedExecutionState[KEY]))
        end

        def clear!
          ActiveSupport::IsolatedExecutionState[KEY] = []
        end

        private

        def scrub(tags)
          Sanitizer.call(tags).deep_dup
        end
      end
    end
  end
end
