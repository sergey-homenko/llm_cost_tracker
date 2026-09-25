# frozen_string_literal: true

require "active_support/core_ext/string/inflections"

require_relative "../ledger/storable"
require_relative "../redaction"

module LlmCostTracker
  module Tags
    module Sanitizer
      REDACTED_VALUE = Redaction::REDACTED

      class << self
        def call(tags, config: LlmCostTracker.configuration)
          tags = (tags || {}).to_h
          redacted = config.tags.normalized_redacted_keys
          limit = [config.tags.max_value_bytesize.to_i, 0].max
          max_count = [config.tags.max_count.to_i, 0].max
          tags.to_a.last(max_count).each_with_object({}) do |(key, value), sanitized|
            next unless valid_key?(key)

            sanitized[key] = sanitized_value(key, value, redacted, limit)
          end
        end

        def valid_key?(key)
          Tags::Key.validate!(key)
          true
        rescue ArgumentError => e
          Logging.warn("LlmCostTracker tag key invalid: #{e.message}; skipping")
          false
        end

        def cap(tags, config: LlmCostTracker.configuration)
          tags = (tags || {}).to_h
          max_count = [config.tags.max_count.to_i, 0].max
          return tags if tags.size <= max_count

          tags.to_a.last(max_count).to_h
        end

        def normalized_key(key)
          key.to_s.underscore.gsub(/[^a-z0-9]+/, "_").delete_prefix("_").delete_suffix("_")
        end

        private

        def sanitized_value(key, value, redacted, limit)
          return REDACTED_VALUE if redacted_key?(key, redacted)

          scalar_truncate(scrub_secrets(Ledger::Storable.clean(value)), limit)
        end

        def scalar_truncate(value, limit)
          case value
          when Hash
            value.transform_values { |nested| scalar_truncate(nested, limit) }
          when Array
            value.map { |nested| scalar_truncate(nested, limit) }
          else
            return value if value == REDACTED_VALUE

            string = value.to_s
            return value if string.bytesize <= limit

            string.byteslice(0, limit).encode("UTF-8", invalid: :replace, undef: :replace)
          end
        end

        def scrub_secrets(value)
          case value
          when Hash
            value.transform_values { |nested| scrub_secrets(nested) }
          when Array
            value.map { |nested| scrub_secrets(nested) }
          else
            string = value.to_s
            scrubbed = Redaction.text(string)
            scrubbed == string ? value : scrubbed
          end
        end

        def redacted_key?(key, redacted)
          return false if redacted.empty?

          normalized = normalized_key(key)
          redacted.any? { |candidate| redacted_key_component?(normalized, candidate) }
        end

        def redacted_key_component?(key, candidate)
          key == candidate ||
            key.start_with?("#{candidate}_") ||
            key.end_with?("_#{candidate}") ||
            key.include?("_#{candidate}_")
        end
      end
    end
  end
end
