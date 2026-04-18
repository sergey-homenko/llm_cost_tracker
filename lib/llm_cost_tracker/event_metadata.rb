# frozen_string_literal: true

module LlmCostTracker
  module EventMetadata
    INTERNAL_TAG_KEYS = %w[
      cache_creation_input_tokens
      cache_creation_tokens
      cache_read_input_tokens
      cache_read_tokens
      cached_input_tokens
      input_tokens
      output_tokens
      reasoning_tokens
      total_tokens
    ].freeze

    class << self
      def usage_data(input_tokens, output_tokens, metadata)
        cache_read_input_tokens = integer_metadata(metadata, :cache_read_input_tokens, :cache_read_tokens)
        cache_creation_input_tokens = integer_metadata(
          metadata,
          :cache_creation_input_tokens,
          :cache_creation_tokens
        )
        cached_input_tokens = integer_metadata(metadata, :cached_input_tokens)

        {
          input_tokens: input_tokens.to_i,
          output_tokens: output_tokens.to_i,
          cached_input_tokens: cached_input_tokens,
          cache_read_input_tokens: cache_read_input_tokens,
          cache_creation_input_tokens: cache_creation_input_tokens,
          total_tokens: input_tokens.to_i + output_tokens.to_i +
            cache_read_input_tokens + cache_creation_input_tokens
        }
      end

      def tags(metadata)
        metadata.reject { |key, _value| INTERNAL_TAG_KEYS.include?(key.to_s) }
      end

      private

      def integer_metadata(metadata, *keys)
        keys.each do |key|
          value = metadata[key] || metadata[key.to_s]
          return value.to_i unless value.nil?
        end

        0
      end
    end
  end
end
