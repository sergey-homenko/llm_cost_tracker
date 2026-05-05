# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
require "json"

module LlmCostTracker
  module Tags
    module Sanitizer
      REDACTED_VALUE = "[REDACTED]"

      class << self
        def call(tags, config: LlmCostTracker.configuration)
          tags = (tags || {}).to_h
          redacted = Array(config.redacted_tag_keys).map { |key| normalized_key(key) }
          limit = [config.max_tag_value_bytesize.to_i, 0].max
          tags.first([config.max_tag_count.to_i, 0].max).each_with_object({}) do |(key, value), sanitized|
            sanitized[key] = sanitized_value(key, value, redacted, limit)
          end
        end

        private

        def sanitized_value(key, value, redacted, limit)
          return REDACTED_VALUE if redacted_key?(key, redacted)

          string = value_string(value)
          return value if string.bytesize <= limit

          string.byteslice(0, limit).encode("UTF-8", invalid: :replace, undef: :replace)
        end

        def redacted_key?(key, redacted)
          return false if redacted.empty?

          normalized = normalized_key(key)
          redacted.any? { |candidate| redacted_key_component?(normalized, candidate) }
        end

        def normalized_key(key)
          key.to_s.underscore.gsub(/[^a-z0-9]+/, "_").delete_prefix("_").delete_suffix("_")
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
      end
    end
  end
end
