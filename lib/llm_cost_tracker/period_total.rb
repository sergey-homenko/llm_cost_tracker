# frozen_string_literal: true

require "active_record"

module LlmCostTracker
  class PeriodTotal < ActiveRecord::Base
    self.table_name = "llm_cost_tracker_period_totals"
  end
end
