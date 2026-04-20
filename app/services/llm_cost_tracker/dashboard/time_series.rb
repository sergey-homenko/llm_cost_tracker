# frozen_string_literal: true

require "date"

module LlmCostTracker
  module Dashboard
    class TimeSeries
      DEFAULT_DAYS = 30

      class << self
        def call(scope: LlmCostTracker::LlmApiCall.all, from: nil, to: Date.current)
          new(scope: scope, from: from, to: to).points
        end
      end

      def initialize(scope:, from:, to:)
        @scope = scope
        @to = to.to_date
        @from = from ? from.to_date : (@to - (DEFAULT_DAYS - 1))
      end

      def points
        costs = scoped_costs

        (from..to).map do |date|
          label = date.iso8601
          { label: label, cost: costs.fetch(label, 0.0) }
        end
      end

      private

      attr_reader :scope, :from, :to

      def scoped_costs
        scope
          .where(tracked_at: from.beginning_of_day..to.end_of_day)
          .group_by_period(:day)
          .sum(:total_cost)
          .transform_values(&:to_f)
      end
    end
  end
end
