# frozen_string_literal: true

module LlmCostTracker
  class CallTag < ActiveRecord::Base
    belongs_to :call,
               class_name: "LlmCostTracker::Call",
               foreign_key: :llm_cost_tracker_call_id,
               inverse_of: :tag_records
  end
end
