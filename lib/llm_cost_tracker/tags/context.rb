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
          ActiveSupport::IsolatedExecutionState[KEY] = stack + [(tags || {}).deep_dup.to_h]
          yield
        ensure
          ActiveSupport::IsolatedExecutionState[KEY] = stack
        end

        def tags
          default_tags = LlmCostTracker.configuration.default_tags
          default_tags = default_tags.call.deep_dup if default_tags.respond_to?(:call)

          default_tags.to_h.merge(
            (ActiveSupport::IsolatedExecutionState[KEY] || []).reduce({}) { |merged, tags| merged.merge(tags) }
          )
        end

        def clear!
          ActiveSupport::IsolatedExecutionState[KEY] = []
        end
      end
    end
  end
end
