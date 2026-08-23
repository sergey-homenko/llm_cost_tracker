# frozen_string_literal: true

require_relative "section"

module LlmCostTracker
  class Configuration
    class Pricing < Section
      UNKNOWN_BEHAVIORS = %i[ignore warn raise].freeze

      attributes :file
      enum_attribute :unknown_model_behavior, allowed: UNKNOWN_BEHAVIORS, default: :warn

      attr_reader :overrides

      def initialize(owner)
        super
        @file = nil
        self.overrides = {}
        self.unknown_model_behavior = :warn
      end

      def overrides=(value)
        ensure_mutable!
        @overrides = LlmCostTracker::Pricing::Registry.normalize_price_entries(
          value || {}, context: "pricing_overrides"
        )
      rescue ArgumentError, TypeError => e
        raise Error, "invalid pricing.overrides: #{e.message}"
      end

      def finalize!
        @overrides = deep_freeze(@overrides || {})
      end
    end
  end
end
