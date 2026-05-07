# frozen_string_literal: true

require_relative "billing/components"
require_relative "logging"

module LlmCostTracker
  KNOWN_TOKEN_KEYS = (
    Billing::Components::TOKEN_PRICED.map(&:key) + %i[total hidden_output]
  ).freeze

  TokenUsage = Data.define(
    :input_tokens,
    :cache_read_input_tokens,
    :cache_write_input_tokens,
    :cache_write_extended_input_tokens,
    :audio_input_tokens,
    :output_tokens,
    :audio_output_tokens,
    :total_tokens,
    :hidden_output_tokens
  ) do
    def self.build_from_tokens(tokens)
      return tokens if tokens.is_a?(self)
      raise ArgumentError, "tokens must be a Hash, got #{tokens.class}" unless tokens.respond_to?(:to_h)

      values = tokens.to_h.transform_keys { |key| key.to_s.to_sym }
      warn_on_unknown_keys(values)
      token_attributes = Billing::Components::TOKEN_PRICED.to_h do |component|
        [component.token_key, values.fetch(component.key, 0)]
      end

      build(
        **token_attributes,
        total_tokens: values[:total],
        hidden_output_tokens: values.fetch(:hidden_output, 0)
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
                   total_tokens: nil, hidden_output_tokens: 0)
      input = non_negative_int(input_tokens)
      output = non_negative_int(output_tokens)
      cache_read = non_negative_int(cache_read_input_tokens)
      cache_write = non_negative_int(cache_write_input_tokens)
      cache_write_extended = non_negative_int(cache_write_extended_input_tokens)
      audio_input = non_negative_int(audio_input_tokens)
      audio_output = non_negative_int(audio_output_tokens)
      hidden_output = non_negative_int(hidden_output_tokens)
      calculated_total = input + cache_read + cache_write + cache_write_extended + audio_input + output + audio_output
      total = total_tokens.nil? ? calculated_total : [non_negative_int(total_tokens), calculated_total].max

      new(
        input_tokens: input,
        cache_read_input_tokens: cache_read,
        cache_write_input_tokens: cache_write,
        cache_write_extended_input_tokens: cache_write_extended,
        audio_input_tokens: audio_input,
        output_tokens: output,
        audio_output_tokens: audio_output,
        total_tokens: total,
        hidden_output_tokens: hidden_output
      )
    end
  end
end
