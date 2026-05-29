# frozen_string_literal: true

module LlmCostTracker
  module Ingestion
    class InboxEntry < ActiveRecord::Base
      MAX_ATTEMPTS_BEFORE_QUARANTINE = 5

      def self.pending_total_sql(start:, finish:)
        table = connection.quote_table_name(table_name)
        total_cost = connection.quote_column_name("total_cost")
        tracked_at = connection.quote_column_name("tracked_at")
        attempts = connection.quote_column_name("attempts")
        "COALESCE((SELECT SUM(#{total_cost}) FROM #{table} " \
          "WHERE #{attempts} < #{MAX_ATTEMPTS_BEFORE_QUARANTINE} " \
          "AND #{tracked_at} BETWEEN #{connection.quote(start)} AND #{connection.quote(finish)}), 0)"
      end
    end
  end
end
