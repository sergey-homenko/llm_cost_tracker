# frozen_string_literal: true

require "json"

module LlmCostTracker
  module TagSanitizer
    REDACTED_VALUE = "[REDACTED]"

    class << self
      def call(tags, config: LlmCostTracker.configuration)
        tags = (tags || {}).to_h
        tags.first(max_tag_count(config)).each_with_object({}) do |(key, value), sanitized|
          sanitized[key] = sanitized_value(key, value, config)
        end
      end

      private

      def sanitized_value(key, value, config)
        return REDACTED_VALUE if redacted_key?(key, config)

        string = value_string(value)
        return value if string.bytesize <= max_tag_value_bytesize(config)

        truncate_bytes(string, max_tag_value_bytesize(config))
      end

      def redacted_key?(key, config)
        normalized = key.to_s.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase.tr("-", "_")
        redacted_keys(config).any? do |candidate|
          normalized == candidate || normalized.end_with?("_#{candidate}")
        end
      end

      def redacted_keys(config)
        Array(config.redacted_tag_keys).map { |key| key.to_s.downcase.tr("-", "_") }
      end

      def value_string(value)
        case value
        when Hash, Array
          JSON.generate(value)
        else
          value.to_s
        end
      rescue JSON::GeneratorError, TypeError
        value.to_s
      end

      def truncate_bytes(string, limit)
        string.byteslice(0, limit).to_s.encode("UTF-8", invalid: :replace, undef: :replace)
      end

      def max_tag_count(config)
        [config.max_tag_count.to_i, 0].max
      end

      def max_tag_value_bytesize(config)
        [config.max_tag_value_bytesize.to_i, 0].max
      end
    end
  end
end
