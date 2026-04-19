# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    class TopTags
      DEFAULT_KEYS = ["feature"].freeze
      DEFAULT_LIMIT = 5

      class << self
        def call(scope: LlmCostTracker::LlmApiCall.all, keys: DEFAULT_KEYS, limit: DEFAULT_LIMIT)
          new(scope: scope, keys: keys, limit: limit).groups
        end
      end

      def initialize(scope:, keys:, limit:)
        @scope = scope
        @keys = keys
        @limit = limit
      end

      def groups
        keys.each_with_object({}) do |key, breakdowns|
          rows = scope.cost_by_tag(key).first(limit)
          breakdowns[key] = rows if rows.any?
        end
      end

      private

      attr_reader :scope, :keys, :limit
    end
  end
end
