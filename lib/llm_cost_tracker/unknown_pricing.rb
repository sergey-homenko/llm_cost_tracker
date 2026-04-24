# frozen_string_literal: true

require "monitor"

require_relative "logging"

module LlmCostTracker
  class UnknownPricing
    MUTEX = Monitor.new

    class << self
      def handle!(model)
        model = normalized_model_name(model)

        case behavior
        when :ignore
          nil
        when :warn
          warn_missing(model)
        when :raise
          raise UnknownPricingError.new(model: model)
        end
      end

      def reset!
        MUTEX.synchronize { @warned_models = Set.new }
      end

      private

      def normalized_model_name(model)
        model.to_s.empty? ? "unknown" : model.to_s
      end

      def warn_missing(model)
        should_warn = MUTEX.synchronize do
          @warned_models ||= Set.new
          @warned_models.add?(model)
        end
        return unless should_warn

        Logging.warn(
          "No pricing configured for model #{model.inspect}. " \
          "Cost and budget guardrails will be skipped for this event. " \
          "Add a pricing_overrides entry or set unknown_pricing_behavior."
        )
      end

      def behavior
        LlmCostTracker.configuration.unknown_pricing_behavior
      end
    end
  end
end
