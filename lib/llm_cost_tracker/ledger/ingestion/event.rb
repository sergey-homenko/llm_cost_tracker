# frozen_string_literal: true

require "active_record"

module LlmCostTracker
  class Ledger
    module Ingestion
      class Event < ActiveRecord::Base
        self.table_name = "llm_cost_tracker_inbox_events"
      end
    end
  end
end
