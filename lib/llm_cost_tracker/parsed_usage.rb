# frozen_string_literal: true

module LlmCostTracker
  ParsedUsage = Data.define(
    :provider,
    :model,
    :input_tokens,
    :output_tokens,
    :total_tokens,
    :cache_read_input_tokens,
    :cache_write_input_tokens,
    :hidden_output_tokens,
    :stream,
    :usage_source,
    :provider_response_id
  )

  class ParsedUsage
    TRACKING_KEYS = %i[
      provider
      model
      input_tokens
      output_tokens
      total_tokens
      stream
      usage_source
      provider_response_id
    ].freeze

    def self.build(**attributes)
      new(
        provider: attributes.fetch(:provider),
        model: attributes.fetch(:model),
        input_tokens: attributes.fetch(:input_tokens).to_i,
        output_tokens: attributes.fetch(:output_tokens).to_i,
        total_tokens: attributes.fetch(:total_tokens, usage_breakdown(attributes).total_tokens).to_i,
        cache_read_input_tokens: attributes[:cache_read_input_tokens],
        cache_write_input_tokens: attributes[:cache_write_input_tokens],
        hidden_output_tokens: attributes[:hidden_output_tokens],
        stream: attributes[:stream] || false,
        usage_source: attributes[:usage_source],
        provider_response_id: attributes[:provider_response_id]
      )
    end

    def metadata
      to_h.except(*TRACKING_KEYS)
    end

    def to_h
      super.compact
    end

    def self.usage_breakdown(attributes)
      UsageBreakdown.build(
        input_tokens: attributes.fetch(:input_tokens),
        output_tokens: attributes.fetch(:output_tokens),
        cache_read_input_tokens: attributes[:cache_read_input_tokens],
        cache_write_input_tokens: attributes[:cache_write_input_tokens],
        hidden_output_tokens: attributes[:hidden_output_tokens]
      )
    end
    private_class_method :usage_breakdown
  end
end
