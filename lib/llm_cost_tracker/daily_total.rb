# frozen_string_literal: true

require "active_record"

module LlmCostTracker
  class DailyTotal < ActiveRecord::Base
    self.table_name = "llm_cost_tracker_daily_totals"
  end
end
