# frozen_string_literal: true

require "active_record"

module LlmCostTracker
  module Ingestion
    class Lease < ActiveRecord::Base
      self.table_name = "llm_cost_tracker_ingestion_leases"
    end
  end
end
