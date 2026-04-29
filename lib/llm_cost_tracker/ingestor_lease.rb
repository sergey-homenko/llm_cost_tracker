# frozen_string_literal: true

require "active_record"

module LlmCostTracker
  class IngestorLease < ActiveRecord::Base
    self.table_name = "llm_cost_tracker_ingestor_leases"
  end
end
