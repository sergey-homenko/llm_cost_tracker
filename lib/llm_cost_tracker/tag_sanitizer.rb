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
        normalized = normalized_key(key)
        redacted_keys(config).any? do |candidate|
          redacted_key_component?(normalized, candidate)
        end
      end

      def redacted_keys(config)
        Array(config.redacted_tag_keys).map { |key| normalized_key(key) }
      end

      def normalized_key(key)
        key.to_s
           .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
           .gsub(/([a-z\d])([A-Z])/, '\1_\2')
           .downcase
           .gsub(/[^a-z0-9]+/, "_")
           .gsub(/_+/, "_")
           .delete_prefix("_")
           .delete_suffix("_")
      end

      def redacted_key_component?(key, candidate)
        key == candidate ||
          key.start_with?("#{candidate}_") ||
          key.end_with?("_#{candidate}") ||
          key.include?("_#{candidate}_")
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
