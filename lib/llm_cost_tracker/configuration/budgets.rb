# frozen_string_literal: true

require "bigdecimal"

require_relative "section"

module LlmCostTracker
  class Configuration
    class Budgets < Section
      EXCEEDED_BEHAVIORS = %i[notify raise block_requests].freeze
      TOTALS_SOURCES = %i[ledger cache].freeze
      PER_TAG_WINDOWS = %i[daily weekly monthly].freeze
      PER_TAG_OPTIONS = %i[behavior on_exceeded].freeze

      attributes :monthly, :daily, :per_call, :on_exceeded
      enum_attribute :exceeded_behavior, allowed: EXCEEDED_BEHAVIORS, default: :notify
      enum_attribute :totals_source, allowed: TOTALS_SOURCES, default: :ledger

      attr_reader :per_tag

      def initialize(owner)
        super
        @monthly = nil
        @daily = nil
        @per_call = nil
        @on_exceeded = nil
        @per_tag = {}
        self.exceeded_behavior = :notify
        self.totals_source = :ledger
      end

      def per_tag=(value)
        ensure_mutable!
        @per_tag = (value || {}).to_h.to_h { |key, entry| [validated_key(key), validated_entry(key, entry)] }
      end

      def finalize!
        @per_tag = deep_freeze(@per_tag || {})
      end

      private

      def validated_key(key)
        LlmCostTracker::Tags::Key.validate!(key, error_class: Error)
      end

      def validated_entry(key, entry)
        raise Error, "budgets.per_tag[#{key.inspect}] must be a hash" unless entry.is_a?(Hash)

        normalized = entry.to_h.transform_keys(&:to_sym)
        windows, options = normalized.partition { |name, _| !PER_TAG_OPTIONS.include?(name) }.map(&:to_h)
        if windows.empty?
          raise Error,
                "budgets.per_tag[#{key.inspect}] needs at least one of: #{PER_TAG_WINDOWS.join(', ')}"
        end

        {
          windows: windows.to_h do |window, limit|
                     [validated_window(key, window), validated_limit(key, window, limit)]
                   end,
          behavior: validated_behavior(key, options[:behavior]),
          on_exceeded: options[:on_exceeded]
        }
      end

      def validated_behavior(key, behavior)
        return nil if behavior.nil?
        return behavior.to_sym if EXCEEDED_BEHAVIORS.include?(behavior.to_sym)

        raise Error,
              "Unknown budgets.per_tag[#{key.inspect}] behavior: #{behavior.inspect}. " \
              "Use one of: #{EXCEEDED_BEHAVIORS.join(', ')}"
      end

      def validated_window(key, window)
        return window.to_sym if PER_TAG_WINDOWS.include?(window.to_sym)

        raise Error,
              "Unknown budgets.per_tag[#{key.inspect}] window: #{window.inspect}. " \
              "Use one of: #{PER_TAG_WINDOWS.join(', ')}"
      end

      def validated_limit(key, window, limit)
        numeric = Float(limit, exception: false)
        return BigDecimal(limit.to_s) if numeric&.positive?

        raise Error,
              "budgets.per_tag[#{key.inspect}][#{window.inspect}] must be a positive number, " \
              "got #{limit.inspect}"
      end
    end
  end
end
