# frozen_string_literal: true

module LlmCostTracker
  class CallRollup < ActiveRecord::Base
    def self.total_sql(period:, period_start:)
      table = connection.quote_table_name(table_name)
      "(SELECT SUM(total_cost) FROM #{table} " \
        "WHERE period = #{connection.quote(period.to_s)} " \
        "AND period_start = #{connection.quote(period_start)})"
    end
  end
end
