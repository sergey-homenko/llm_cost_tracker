# frozen_string_literal: true

require_relative "value_object"

module LlmCostTracker
  ParsedUsage = ValueObject.define(
    :provider,
    :model,
    :input_tokens,
    :output_tokens,
    :total_tokens,
    :cached_input_tokens,
    :cache_read_input_tokens,
    :cache_creation_input_tokens,
    :reasoning_tokens
  )

  ParsedUsage.const_set(:TRACKING_KEYS, %i[provider model input_tokens output_tokens total_tokens].freeze)

  class << ParsedUsage
    def build(**attributes)
      new(
        provider: attributes.fetch(:provider),
        model: attributes.fetch(:model),
        input_tokens: attributes.fetch(:input_tokens).to_i,
        output_tokens: attributes.fetch(:output_tokens).to_i,
        total_tokens: attributes.fetch(:total_tokens, 0).to_i,
        cached_input_tokens: attributes[:cached_input_tokens],
        cache_read_input_tokens: attributes[:cache_read_input_tokens],
        cache_creation_input_tokens: attributes[:cache_creation_input_tokens],
        reasoning_tokens: attributes[:reasoning_tokens]
      )
    end
  end

  class ParsedUsage
    def metadata
      except(*TRACKING_KEYS)
    end

    def to_h
      super.compact
    end
  end
end
