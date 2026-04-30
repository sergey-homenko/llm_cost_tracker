# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    class ProviderBreakdown
      def self.call(scope: LlmCostTracker::Ledger::Call.all)
        new(scope: scope).rows
      end

      def initialize(scope:)
        @scope = scope
      end

      def rows
        scope
          .group(:provider)
          .select(selects)
          .order(Arel.sql("total_cost DESC, calls DESC"))
      end

      private

      attr_reader :scope

      def selects
        <<~SQL.squish
          provider,
          COUNT(*) AS calls,
          COALESCE(SUM(total_cost), 0) AS total_cost,
          CASE
            WHEN SUM(COALESCE(SUM(total_cost), 0)) OVER () > 0
              THEN COALESCE(SUM(total_cost), 0) / SUM(COALESCE(SUM(total_cost), 0)) OVER () * 100.0
            ELSE 0
          END AS share_percent
        SQL
      end
    end
  end
end
