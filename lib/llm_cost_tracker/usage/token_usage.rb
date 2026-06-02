# frozen_string_literal: true

require_relative "catalog"

module LlmCostTracker
  module Usage
    KNOWN_TOKEN_KEYS = (
      Catalog.token_priced.map { |dimension| dimension.token_key.to_s } + %w[total_tokens hidden_output_tokens]
    ).freeze

    TokenUsage = Data.define(
      :input_tokens,
      :cache_read_input_tokens,
      :cache_write_input_tokens,
      :cache_write_extended_input_tokens,
      :audio_input_tokens,
      :image_input_tokens,
      :output_tokens,
      :audio_output_tokens,
      :image_output_tokens,
      :total_tokens,
      :hidden_output_tokens
    ) do
      def priced_quantities
        Catalog.token_priced.to_h { |dimension| [dimension.key, public_send(dimension.token_key)] }
      end

      def self.build_from_tokens(tokens)
        return tokens if tokens.is_a?(self)
        raise ArgumentError, "tokens must be a Hash, got #{tokens.class}" unless tokens.respond_to?(:to_h)

        values = tokens.to_h.transform_keys(&:to_s)
        warn_on_unknown_keys(values)
        token_attributes = Catalog.token_priced.to_h do |dimension|
          [dimension.token_key, values.fetch(dimension.token_key.to_s, 0)]
        end

        build(
          **token_attributes,
          total_tokens: values["total_tokens"],
          hidden_output_tokens: values.fetch("hidden_output_tokens", 0)
        )
      end

      def self.warn_on_unknown_keys(values)
        return if values.empty?
        return if values.keys.intersect?(KNOWN_TOKEN_KEYS)

        Logging.warn(
          "tokens hash contains no recognized keys (#{values.keys.inspect}); " \
          "expected one of #{KNOWN_TOKEN_KEYS.inspect}. Did you pass a raw provider response?"
        )
      end

      def self.non_negative_int(value)
        [value.to_i, 0].max
      end

      def self.build(input_tokens:, output_tokens:, cache_read_input_tokens: 0,
                     cache_write_input_tokens: 0, cache_write_extended_input_tokens: 0,
                     audio_input_tokens: 0, audio_output_tokens: 0,
                     image_input_tokens: 0, image_output_tokens: 0,
                     total_tokens: nil, hidden_output_tokens: 0)
        input = non_negative_int(input_tokens)
        output = non_negative_int(output_tokens)
        cache_read = non_negative_int(cache_read_input_tokens)
        cache_write = non_negative_int(cache_write_input_tokens)
        cache_write_extended = non_negative_int(cache_write_extended_input_tokens)
        audio_input = non_negative_int(audio_input_tokens)
        audio_output = non_negative_int(audio_output_tokens)
        image_input = non_negative_int(image_input_tokens)
        image_output = non_negative_int(image_output_tokens)
        hidden_output = non_negative_int(hidden_output_tokens)
        calculated_total = input + cache_read + cache_write + cache_write_extended +
                           audio_input + image_input + output + audio_output + image_output
        total = total_tokens ? [non_negative_int(total_tokens), calculated_total].max : calculated_total

        new(
          input_tokens: input,
          cache_read_input_tokens: cache_read,
          cache_write_input_tokens: cache_write,
          cache_write_extended_input_tokens: cache_write_extended,
          audio_input_tokens: audio_input,
          image_input_tokens: image_input,
          output_tokens: output,
          audio_output_tokens: audio_output,
          image_output_tokens: image_output,
          total_tokens: total,
          hidden_output_tokens: hidden_output
        )
      end
    end
  end
end
