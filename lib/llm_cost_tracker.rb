# frozen_string_literal: true

require "active_support"
require "active_support/notifications"

require_relative "llm_cost_tracker/version"
require_relative "llm_cost_tracker/configuration"
require_relative "llm_cost_tracker/errors"
require_relative "llm_cost_tracker/logging"
require_relative "llm_cost_tracker/cost"
require_relative "llm_cost_tracker/event"
require_relative "llm_cost_tracker/parsed_usage"
require_relative "llm_cost_tracker/price_registry"
require_relative "llm_cost_tracker/pricing"
require_relative "llm_cost_tracker/parsers/base"
require_relative "llm_cost_tracker/parsers/openai_usage"
require_relative "llm_cost_tracker/parsers/openai"
require_relative "llm_cost_tracker/parsers/openai_compatible"
require_relative "llm_cost_tracker/parsers/anthropic"
require_relative "llm_cost_tracker/parsers/gemini"
require_relative "llm_cost_tracker/parsers/registry"
require_relative "llm_cost_tracker/middleware/faraday"
require_relative "llm_cost_tracker/budget"
require_relative "llm_cost_tracker/unknown_pricing"
require_relative "llm_cost_tracker/event_metadata"
require_relative "llm_cost_tracker/tags_column"
require_relative "llm_cost_tracker/tag_key"
require_relative "llm_cost_tracker/tag_query"
require_relative "llm_cost_tracker/tag_accessors"
require_relative "llm_cost_tracker/tracker"
require_relative "llm_cost_tracker/report_data"
require_relative "llm_cost_tracker/report_formatter"
require_relative "llm_cost_tracker/report"

module LlmCostTracker
  class << self
    attr_writer :configuration

    def configuration
      @configuration ||= Configuration.new
    end

    # Configure the gem once during application boot.
    #
    # @yieldparam configuration [LlmCostTracker::Configuration]
    # @return [void]
    def configure
      yield(configuration)
      configuration.normalize_openai_compatible_providers!
      warn_for_configuration!
    end

    def reset_configuration!
      @configuration = Configuration.new
    end

    # Track an LLM request manually for non-Faraday clients.
    #
    #   LlmCostTracker.track(
    #     provider: :openai,
    #     model: "gpt-4o",
    #     input_tokens: 150,
    #     output_tokens: 50,
    #     feature: "chat",
    #     user_id: current_user.id
    #   )
    #
    # @param provider [String, Symbol] Provider name, such as :openai or :anthropic.
    # @param model [String] Provider model identifier.
    # @param input_tokens [Integer] Billed input token count.
    # @param output_tokens [Integer] Billed output token count.
    # @param latency_ms [Integer, nil] Optional request latency in milliseconds.
    # @param metadata [Hash] Attribution tags and provider-specific usage metadata.
    # @return [LlmCostTracker::Event] The tracked event.
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
      return unless configuration.budget_exceeded_behavior == :block_requests
      return if configuration.active_record?

      Logging.warn(":block_requests requires storage_backend = :active_record; preflight blocking will be skipped.")
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
