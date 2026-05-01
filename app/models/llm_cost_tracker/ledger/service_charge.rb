# frozen_string_literal: true

require "active_record"

module LlmCostTracker
  module Ledger
    class ServiceCharge < ActiveRecord::Base
      self.table_name = "llm_cost_tracker_service_charges"

      belongs_to :call,
                 class_name: "LlmCostTracker::Ledger::Call",
                 foreign_key: :llm_api_call_id,
                 inverse_of: :service_charges
    end
  end
end
