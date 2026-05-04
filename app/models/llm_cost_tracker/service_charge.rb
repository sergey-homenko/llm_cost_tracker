# frozen_string_literal: true

require "active_record"

module LlmCostTracker
  class ServiceCharge < ActiveRecord::Base
    belongs_to :call,
               class_name: "LlmCostTracker::Call",
               foreign_key: :llm_cost_tracker_call_id,
               inverse_of: :service_charges
  end
end
