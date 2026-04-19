# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    ProviderRow = Data.define(:provider, :calls, :total_cost, :share_percent)

    # Aggregates cost and call counts per provider for a given scope.
    # Sorted by total cost descending; providers with zero cost fall to the bottom
    # but are still returned so users can see calls without pricing.
    class ProviderBreakdown
      def self.call(scope: LlmCostTracker::LlmApiCall.all)
        new(scope: scope).rows
      end

      def initialize(scope:)
        @scope = scope
      end

      def rows
        grouped = scope
                  .group(:provider)
                  .select("provider, COUNT(*) AS calls_count, COALESCE(SUM(total_cost), 0) AS total_cost_sum")
                  .order(Arel.sql("total_cost_sum DESC, calls_count DESC"))
                  .to_a

        total_cost = grouped.sum { |row| row.total_cost_sum.to_f }

        grouped.map do |row|
          cost = row.total_cost_sum.to_f
          ProviderRow.new(
            provider: row.provider,
            calls: row.calls_count.to_i,
            total_cost: cost,
            share_percent: total_cost.positive? ? (cost / total_cost) * 100.0 : 0.0
          )
        end
      end

      private

      attr_reader :scope
    end
  end
end
