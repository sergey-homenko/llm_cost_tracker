# frozen_string_literal: true

require "active_record"

module LlmCostTracker
  class CallLineItem < ActiveRecord::Base
    self.table_name = "llm_cost_tracker_call_line_items"

    belongs_to :call,
               class_name: "LlmCostTracker::Call",
               foreign_key: :llm_cost_tracker_call_id,
               inverse_of: :line_items

    scope :tokens, -> { where("kind LIKE ?", "%_token") }
    scope :by_kind, ->(kind) { where(kind: kind.to_s) }
    scope :by_direction, ->(direction) { where(direction: direction.to_s) }
    scope :by_modality, ->(modality) { where(modality: modality.to_s) }
    scope :cached, -> { where.not(cache_state: ["none", nil]) }
    scope :priced, -> { where(cost_status: %w[complete free]) }
    scope :unpriced, -> { where(cost_status: "unknown") }
  end
end
