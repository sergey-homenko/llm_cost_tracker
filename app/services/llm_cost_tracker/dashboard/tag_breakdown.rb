# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    TagBreakdownRow = Data.define(
      :value,
      :calls,
      :total_cost,
      :average_cost_per_call
    )

    class TagBreakdown
      class << self
        def call(key:, scope: LlmCostTracker::LlmApiCall.all)
          new(scope: scope, key: key).rows
        end
      end

      def initialize(scope:, key:)
        @scope = scope
        @key = LlmCostTracker::TagKey.validate!(key, error_class: LlmCostTracker::InvalidFilterError)
      end

      def rows
        costs = scope.cost_by_tag(key)
        counts = counts_by_tag

        costs.map do |value, total_cost|
          calls = counts[value].to_i
          total_cost = total_cost.to_f

          TagBreakdownRow.new(
            value: value,
            calls: calls,
            total_cost: total_cost,
            average_cost_per_call: calls.positive? ? total_cost / calls : 0.0
          )
        end
      end

      private

      attr_reader :scope, :key

      def counts_by_tag
        scope.group_by_tag(key).count.each_with_object(Hash.new(0)) do |(raw, count), hash|
          hash[label(raw)] += count.to_i
        end
      end

      def label(value)
        value.nil? || value == "" ? "(untagged)" : value.to_s
      end
    end
  end
end
