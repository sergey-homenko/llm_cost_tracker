# frozen_string_literal: true

require "bigdecimal"

require_relative "section"

module LlmCostTracker
  class Configuration
    class Budgets < Section
      EXCEEDED_BEHAVIORS = %i[notify raise block_requests].freeze
      TOTALS_SOURCES = %i[ledger cache].freeze
      PER_TAG_WINDOWS = %i[daily weekly monthly total calls].freeze
      PER_TAG_OPTIONS = %i[behavior on_exceeded].freeze

      LIMITS = %i[monthly daily per_call].freeze

      enum_attribute :exceeded_behavior, allowed: EXCEEDED_BEHAVIORS, default: :notify
      enum_attribute :totals_source, allowed: TOTALS_SOURCES, default: :ledger

      attr_reader(*LIMITS, :on_exceeded, :per_tag)

      LIMITS.each do |name|
        define_method(:"#{name}=") do |value|
          ensure_mutable!
          amount = validated_amount("budgets.#{name}", value, minimum: 0) unless value.nil?
          instance_variable_set(:"@#{name}", value.is_a?(Numeric) ? value : amount)
        end
      end

      def on_exceeded=(value)
        ensure_mutable!
        @on_exceeded = validated_callback("budgets.on_exceeded", value)
      end

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
        @per_tag = deep_freeze(@per_tag)
      end

      private

      def validated_key(key)
        LlmCostTracker::Tags::Key.validate!(key, error_class: Error)
      end

      def validated_entry(key, entry)
        raise Error, "budgets.per_tag[#{key.inspect}] must be a hash" unless entry.is_a?(Hash)

        normalized = entry.to_h.transform_keys(&:to_sym)
        {
          windows: validated_windows(key, normalized.except(*PER_TAG_OPTIONS)),
          behavior: validated_behavior(key, normalized[:behavior]),
          on_exceeded: validated_callback("budgets.per_tag[#{key.inspect}][:on_exceeded]", normalized[:on_exceeded])
        }
      end

      def validated_amount(name, value, minimum: nil)
        number = Float(value, exception: false)
        return BigDecimal(value.to_s) if number && (minimum ? number >= minimum : number.positive?)

        raise Error, "#{name} must be a #{minimum ? 'non-negative' : 'positive'} number, got #{value.inspect}"
      end

      def validated_callback(name, value)
        return value if value.nil? || value.respond_to?(:call)

        raise Error, "#{name} must respond to call, got #{value.inspect}"
      end

      def validated_windows(key, windows)
        if windows.empty?
          raise Error, "budgets.per_tag[#{key.inspect}] needs at least one of: #{PER_TAG_WINDOWS.join(', ')}"
        end

        windows.to_h { |window, limit| [validated_window(key, window), validated_limit(key, window, limit)] }
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
        return validated_calls(key, limit) if window == :calls

        validated_amount("budgets.per_tag[#{key.inspect}][#{window.inspect}]", limit)
      end

      def validated_calls(key, limit)
        count = Integer(limit.to_s, exception: false)
        return count if count&.positive?

        raise Error, "budgets.per_tag[#{key.inspect}][:calls] must be a positive integer, got #{limit.inspect}"
      end
    end
  end
end
