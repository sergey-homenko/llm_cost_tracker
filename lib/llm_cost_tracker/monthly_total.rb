# frozen_string_literal: true

require "active_record"

module LlmCostTracker
  class MonthlyTotal < ActiveRecord::Base
    self.table_name = "llm_cost_tracker_monthly_totals"
  end
end
