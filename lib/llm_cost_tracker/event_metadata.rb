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
      provider_response_id
      reasoning_tokens
      total_tokens
    ].freeze

    class << self
      def usage_data(input_tokens, output_tokens, metadata)
        metadata = metadata.to_h.symbolize_keys
        cache_read = first_integer(metadata, :cache_read_input_tokens, :cache_read_tokens)
        cache_creation = first_integer(metadata, :cache_creation_input_tokens, :cache_creation_tokens)

        {
          input_tokens: input_tokens.to_i,
          output_tokens: output_tokens.to_i,
          cached_input_tokens: metadata[:cached_input_tokens].to_i,
          cache_read_input_tokens: cache_read,
          cache_creation_input_tokens: cache_creation,
          total_tokens: input_tokens.to_i + output_tokens.to_i + cache_read + cache_creation
        }
      end

      def tags(metadata)
        metadata.reject { |key, _value| INTERNAL_TAG_KEYS.include?(key.to_s) }
      end

      private

      def first_integer(metadata, *keys)
        keys.each { |key| return metadata[key].to_i unless metadata[key].nil? }
        0
      end
    end
  end
end
