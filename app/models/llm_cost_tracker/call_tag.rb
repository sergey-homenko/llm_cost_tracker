# frozen_string_literal: true

require "active_record"

module LlmCostTracker
  class CallTag < ActiveRecord::Base
    self.table_name = "llm_cost_tracker_call_tags"

    belongs_to :call,
               class_name: "LlmCostTracker::Call",
               foreign_key: :llm_cost_tracker_call_id,
               inverse_of: :tag_records

    scope :with_key, ->(key) { where(key: key.to_s) }
  end
end
