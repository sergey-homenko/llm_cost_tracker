# frozen_string_literal: true

require "active_record"

module LlmCostTracker
  module Ingestion
    class InboxRow < ActiveRecord::Base
      MAX_ATTEMPTS_BEFORE_QUARANTINE = 5

      self.table_name = "llm_cost_tracker_inbox_events"
    end
  end
end
