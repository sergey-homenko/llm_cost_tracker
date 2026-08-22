# frozen_string_literal: true

require_relative "../logging"

module LlmCostTracker
  module Pricing
    module Unknown
      MUTEX = Mutex.new
      WARN_CACHE_LIMIT = 1024

      class << self
        def process(model)
          model = model.to_s.presence || Event::UNKNOWN_MODEL

          case LlmCostTracker.configuration.pricing.unknown_behavior
          when :ignore
            nil
          when :warn
            warn_missing(model)
          when :raise
            raise UnknownPricingError.new(model: model)
          end
        end

        private

        def warn_missing(model)
          should_warn = MUTEX.synchronize do
            @warned_models ||= Set.new
            next false if @warned_models.size >= WARN_CACHE_LIMIT && !@warned_models.include?(model)

            @warned_models.add?(model)
          end
          return unless should_warn

          Logging.warn(
            "No pricing configured for model #{model.inspect}. " \
            "Cost and budget guardrails will be skipped for this event. " \
            "Add a pricing_overrides entry or set unknown_pricing_behavior."
          )
        end
      end
    end
  end
end
