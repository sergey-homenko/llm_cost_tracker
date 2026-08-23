# frozen_string_literal: true

require_relative "section"

module LlmCostTracker
  class Configuration
    class Tags < Section
      DEFAULT_REDACTED_KEYS = %w[api_key access_token authorization credential password refresh_token secret].freeze

      attributes :default, :max_count, :max_value_bytesize

      attr_reader :redacted_keys, :report_breakdown_keys

      def initialize(owner)
        super
        @default = {}
        @max_count = 50
        @max_value_bytesize = 1024
        @redacted_keys = DEFAULT_REDACTED_KEYS.dup
        @report_breakdown_keys = []
      end

      def redacted_keys=(value)
        ensure_mutable!
        @redacted_keys = Array(value).map(&:to_s)
      end

      def report_breakdown_keys=(value)
        ensure_mutable!
        @report_breakdown_keys = Array(value).map { |key| LlmCostTracker::Tags::Key.validate!(key, error_class: Error) }
      end

      def normalized_redacted_keys
        @normalized_redacted_keys ||=
          Array(@redacted_keys).map { |key| LlmCostTracker::Tags::Sanitizer.normalized_key(key) }.freeze
      end

      def static_sanitized_default
        return nil if @default.respond_to?(:call)

        @static_sanitized_default ||=
          LlmCostTracker::Tags::Sanitizer.call((@default || {}).to_h, config: owner).freeze
      end

      def finalize!
        @default = deep_freeze(@default || {})
        @redacted_keys = deep_freeze(Array(@redacted_keys))
        @report_breakdown_keys = deep_freeze(Array(@report_breakdown_keys))
      end
    end
  end
end
