# frozen_string_literal: true

module LlmCostTracker
  class CallLineItem < ActiveRecord::Base
    belongs_to :call,
               class_name: "LlmCostTracker::Call",
               foreign_key: :llm_cost_tracker_call_id,
               inverse_of: :line_items

    scope :tokens, -> { where(unit: "token") }
    scope :by_kind, ->(kind) { where(kind: kind.to_s) }
    scope :by_direction, ->(direction) { where(direction: direction.to_s) }
    scope :by_modality, ->(modality) { where(modality: modality.to_s) }
    scope :cached, -> { where.not(cache_state: ["none", nil]) }
    scope :priced, -> { where(cost_status: [Billing::CostStatus::COMPLETE, Billing::CostStatus::FREE]) }
    scope :unpriced, -> { where(cost_status: Billing::CostStatus::UNKNOWN) }
  end
end
