# frozen_string_literal: true

require "active_record"

module LlmCostTracker
  module Ledger
    module Period
      class Total < ActiveRecord::Base
        self.table_name = "llm_cost_tracker_period_totals"
      end
    end
  end
end
