# frozen_string_literal: true

module LlmCostTracker
  class CallRollup < ActiveRecord::Base
    def self.total_sql(period:, period_start:)
      rollup = where(period: period.to_s, period_start: period_start)
      "(#{rollup.select('SUM(total_cost)').to_sql})"
    end
  end
end
