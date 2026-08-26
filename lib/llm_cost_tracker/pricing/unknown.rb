# frozen_string_literal: true

require_relative "../logging"

module LlmCostTracker
  module Pricing
    module Unknown
      MUTEX = Mutex.new
      WARN_CACHE_LIMIT = 1024

      class << self
        def process(model, pricing_mode: nil)
          model = model.to_s.presence || Event::UNKNOWN_MODEL

          case LlmCostTracker.configuration.pricing.unknown_model_behavior
          when :ignore
            nil
          when :warn
            warn_missing(model, pricing_mode.to_s.presence)
          when :raise
            raise UnknownPricingError.new(model: model)
          end
        end

        private

        def warn_missing(model, pricing_mode)
          key = [model, pricing_mode].freeze
          should_warn = MUTEX.synchronize do
            @warned_models ||= Set.new
            next false if @warned_models.size >= WARN_CACHE_LIMIT && !@warned_models.include?(key)

            @warned_models.add?(key)
          end
          return unless should_warn

          subject = "model #{model.inspect}"
          subject += " at pricing_mode #{pricing_mode.inspect}" if pricing_mode
          Logging.warn(
            "No pricing configured for #{subject}. " \
            "Cost and budget guardrails will be skipped for this event. " \
            "Add a pricing.overrides entry or set pricing.unknown_model_behavior."
          )
        end
      end
    end
  end
end
