# frozen_string_literal: true

require "active_record"

module LlmCostTracker
  module Ingestion
    class Event < ActiveRecord::Base
      MAX_ATTEMPTS = 5

      self.table_name = "llm_cost_tracker_inbox_events"
    end
  end
end
