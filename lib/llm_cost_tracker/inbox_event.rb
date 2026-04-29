# frozen_string_literal: true

require "active_record"

module LlmCostTracker
  class InboxEvent < ActiveRecord::Base
    self.table_name = "llm_cost_tracker_inbox_events"
  end
end
