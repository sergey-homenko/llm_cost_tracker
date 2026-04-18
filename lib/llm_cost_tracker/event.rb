# frozen_string_literal: true

require_relative "value_object"

module LlmCostTracker
  Event = ValueObject.define(
    :provider,
    :model,
    :input_tokens,
    :output_tokens,
    :total_tokens,
    :cost,
    :tags,
    :latency_ms,
    :tracked_at
  ) do
    def to_h
      super.merge(
        cost: cost&.to_h,
        tags: tags ? tags.to_h : {}
      )
    end
  end
end
