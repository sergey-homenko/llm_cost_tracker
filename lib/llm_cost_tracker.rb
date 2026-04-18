# frozen_string_literal: true

require "active_support"
require "active_support/notifications"

require_relative "llm_cost_tracker/version"
require_relative "llm_cost_tracker/configuration"
require_relative "llm_cost_tracker/errors"
require_relative "llm_cost_tracker/price_registry"
require_relative "llm_cost_tracker/pricing"
require_relative "llm_cost_tracker/parsers/base"
require_relative "llm_cost_tracker/parsers/openai"
require_relative "llm_cost_tracker/parsers/openai_compatible"
require_relative "llm_cost_tracker/parsers/anthropic"
require_relative "llm_cost_tracker/parsers/gemini"
require_relative "llm_cost_tracker/parsers/registry"
require_relative "llm_cost_tracker/middleware/faraday"
require_relative "llm_cost_tracker/budget"
require_relative "llm_cost_tracker/unknown_pricing"
require_relative "llm_cost_tracker/event_metadata"
require_relative "llm_cost_tracker/tracker"

module LlmCostTracker
  class << self
    CONFIGURATION_MUTEX = Mutex.new

    attr_writer :configuration

    def configuration
      @configuration || CONFIGURATION_MUTEX.synchronize { @configuration ||= Configuration.new }
    end

    def configure
      yield(configuration)
      configuration.normalize_openai_compatible_providers!
      warn_for_configuration!
    end

    def reset_configuration!
      CONFIGURATION_MUTEX.synchronize { @configuration = Configuration.new }
    end

    # Manual tracking for non-Faraday clients
    #
    #   LlmCostTracker.track(
    #     provider: :openai,
    #     model: "gpt-4o",
    #     input_tokens: 150,
    #     output_tokens: 50,
    #     feature: "chat",
    #     user_id: current_user.id
    #   )
    def track(provider:, model:, input_tokens:, output_tokens:, latency_ms: nil, **metadata)
      Tracker.record(
        provider: provider.to_s,
        model: model,
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        latency_ms: latency_ms,
        metadata: metadata
      )
    end

    private

    def warn_for_configuration!
      return unless (configuration.budget_exceeded_behavior || :notify).to_sym == :block_requests
      return if configuration.active_record?

      log_warning(":block_requests requires storage_backend = :active_record; preflight blocking will be skipped.")
    end

    def log_warning(message)
      message = "[LlmCostTracker] #{message}"

      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.warn(message)
      else
        warn message
      end
    end
  end
end

# Load Railtie if Rails is present
require_relative "llm_cost_tracker/railtie" if defined?(Rails::Railtie)

# Auto-register Faraday middleware
if defined?(Faraday)
  Faraday::Middleware.register_middleware(
    llm_cost_tracker: LlmCostTracker::Middleware::Faraday
  )
end
