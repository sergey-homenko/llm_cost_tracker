# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
require "json"

module LlmCostTracker
  module Tags
    module Sanitizer
      REDACTED_VALUE = "[REDACTED]"

      SECRET_VALUE_PATTERNS = [
        /\Ask-(?:ant-|admin-|proj-|live-|test-)?[A-Za-z0-9_-]{16,}\z/,
        /\AAKIA[0-9A-Z]{16}\z/,
        /\Agh[opsur]_[A-Za-z0-9]{16,}\z/,
        /\Agithub_pat_[A-Za-z0-9_]{20,}\z/,
        /\Aeyj[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\z/i,
        /\Abearer\s+[A-Za-z0-9_.-]{20,}\z/i
      ].freeze
      private_constant :SECRET_VALUE_PATTERNS

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
          return REDACTED_VALUE if secret_shaped?(string)
          return value if string.bytesize <= limit

          string.byteslice(0, limit).encode("UTF-8", invalid: :replace, undef: :replace)
        end

        def secret_shaped?(string)
          SECRET_VALUE_PATTERNS.any? { |pattern| pattern.match?(string) }
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
