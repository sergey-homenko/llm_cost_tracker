# frozen_string_literal: true

require "active_support/isolated_execution_state"

require_relative "value_helpers"

module LlmCostTracker
  module TagContext
    KEY = :llm_cost_tracker_tags

    class << self
      def with(tags)
        stack = current_stack
        ActiveSupport::IsolatedExecutionState[KEY] = stack + [normalize(tags)]
        yield
      ensure
        ActiveSupport::IsolatedExecutionState[KEY] = stack
      end

      def tags
        config_tags.merge(scoped_tags)
      end

      def clear!
        ActiveSupport::IsolatedExecutionState[KEY] = []
      end

      private

      def config_tags
        normalize(resolve_default_tags)
      end

      def resolve_default_tags
        tags = LlmCostTracker.configuration.default_tags
        tags.respond_to?(:call) ? tags.call : tags
      end

      def scoped_tags
        current_stack.reduce({}) { |merged, tags| merged.merge(tags) }
      end

      def current_stack
        ActiveSupport::IsolatedExecutionState[KEY] || []
      end

      def normalize(tags)
        ValueHelpers.deep_dup(tags || {}).to_h
      end
    end
  end
end
