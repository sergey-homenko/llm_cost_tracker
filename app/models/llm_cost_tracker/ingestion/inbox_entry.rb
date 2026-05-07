# frozen_string_literal: true

require "active_record"

module LlmCostTracker
  module Ingestion
    class InboxEntry < ActiveRecord::Base
      self.table_name = "llm_cost_tracker_ingestion_inbox_entries"

      MAX_ATTEMPTS_BEFORE_QUARANTINE = 5
    end
  end
end
