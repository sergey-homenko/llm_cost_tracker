# frozen_string_literal: true

require "active_record"

module LlmCostTracker
  class CallRollup < ActiveRecord::Base
    self.table_name = "llm_cost_tracker_call_rollups"
  end
end
