# frozen_string_literal: true

module LlmCostTracker
  Event = Data.define(
    :event_id,
    :provider,
    :model,
    :token_usage,
    :pricing_mode,
    :cost,
    :tags,
    :latency_ms,
    :stream,
    :usage_source,
    :provider_response_id,
    :tracked_at
  ) do
    def total_cost
      cost&.fetch(:total_cost, nil)
    end

    def to_h
      super.merge(
        token_usage: token_usage.to_h,
        cost: cost&.to_h,
        tags: tags ? tags.to_h : {}
      )
    end
  end
end
