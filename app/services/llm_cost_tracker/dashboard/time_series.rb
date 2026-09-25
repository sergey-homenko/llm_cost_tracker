# frozen_string_literal: true

require "date"

module LlmCostTracker
  module Dashboard
    class TimeSeries
      class << self
        def call(from:, to:, scope: LlmCostTracker::Call.all)
          new(scope: scope, from: from, to: to).points
        end
      end

      def initialize(scope:, from:, to:)
        @scope = scope
        @from = from.to_date
        @to = to.to_date
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
          .group_by_period(:day, time_zone: Time.zone)
          .sum(:total_cost)
          .transform_values(&:to_f)
      end
    end
  end
end
