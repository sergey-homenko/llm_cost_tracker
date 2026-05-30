# frozen_string_literal: true

module LlmCostTracker
  module Ingestion
    class InboxEntry < ActiveRecord::Base
      MAX_ATTEMPTS_BEFORE_QUARANTINE = 5

      def self.pending_total_sql(start:, finish:)
        pending = where("attempts < ?", MAX_ATTEMPTS_BEFORE_QUARANTINE).where(tracked_at: start..finish)
        "COALESCE((#{pending.select('SUM(total_cost)').to_sql}), 0)"
      end
    end
  end
end
