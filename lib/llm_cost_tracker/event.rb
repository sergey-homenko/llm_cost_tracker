# frozen_string_literal: true

module LlmCostTracker
  Event = Data.define(
    :provider,
    :model,
    :input_tokens,
    :output_tokens,
    :total_tokens,
    :cost,
    :tags,
    :latency_ms,
    :stream,
    :usage_source,
    :provider_response_id,
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
