# frozen_string_literal: true

module LlmCostTracker
  module EventMetadata
    INTERNAL_TAG_KEYS = %w[
      cache_read_input_tokens
      cache_write_input_tokens
      hidden_output_tokens
      input_tokens
      output_tokens
      pricing_mode
      provider_response_id
      total_tokens
    ].freeze

    class << self
      def usage_data(input_tokens, output_tokens, metadata)
        metadata = metadata.to_h.symbolize_keys
        cache_read = first_integer(metadata, :cache_read_input_tokens)
        cache_write = first_integer(metadata, :cache_write_input_tokens)
        hidden_output = first_integer(metadata, :hidden_output_tokens)
        breakdown = UsageBreakdown.build(
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          cache_read_input_tokens: cache_read,
          cache_write_input_tokens: cache_write,
          hidden_output_tokens: hidden_output
        )

        breakdown.to_h.merge(pricing_mode: normalized_pricing_mode(metadata[:pricing_mode])).compact
      end

      def tags(metadata)
        metadata.reject { |key, _value| INTERNAL_TAG_KEYS.include?(key.to_s) }
      end

      private

      def first_integer(metadata, *keys)
        keys.each { |key| return metadata[key].to_i unless metadata[key].nil? }
        0
      end

      def normalized_pricing_mode(value)
        return nil if value.nil?

        mode = value.to_s.strip
        mode.empty? || mode == "standard" ? nil : mode
      end
    end
  end
end
