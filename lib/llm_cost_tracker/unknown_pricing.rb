# frozen_string_literal: true

module LlmCostTracker
  class UnknownPricing
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

      private

      def normalized_model_name(model)
        model.to_s.empty? ? "unknown" : model.to_s
      end

      def warn_missing(model)
        message = "[LlmCostTracker] No pricing configured for model #{model.inspect}. " \
                  "Cost and budget enforcement will be skipped for this event. " \
                  "Add a pricing_overrides entry or set unknown_pricing_behavior."

        if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
          Rails.logger.warn(message)
        else
          Kernel.warn(message)
        end
      end

      def behavior
        behavior = (LlmCostTracker.configuration.unknown_pricing_behavior || :warn).to_sym
        return behavior if Configuration::UNKNOWN_PRICING_BEHAVIORS.include?(behavior)

        raise Error,
              "Unknown unknown_pricing_behavior: #{behavior.inspect}. " \
              "Use one of: #{Configuration::UNKNOWN_PRICING_BEHAVIORS.join(', ')}"
      end
    end
  end
end
