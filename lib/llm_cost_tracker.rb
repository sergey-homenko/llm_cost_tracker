# frozen_string_literal: true

require "active_support"
require "active_support/notifications"

require_relative "llm_cost_tracker/version"
require_relative "llm_cost_tracker/configuration"
require_relative "llm_cost_tracker/pricing"
require_relative "llm_cost_tracker/parsers/base"
require_relative "llm_cost_tracker/parsers/openai"
require_relative "llm_cost_tracker/parsers/anthropic"
require_relative "llm_cost_tracker/parsers/gemini"
require_relative "llm_cost_tracker/parsers/registry"
require_relative "llm_cost_tracker/middleware/faraday"
require_relative "llm_cost_tracker/tracker"

module LlmCostTracker
  class Error < StandardError; end

  class << self
    attr_writer :configuration

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def reset_configuration!
      @configuration = Configuration.new
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
    def track(provider:, model:, input_tokens:, output_tokens:, **metadata)
      Tracker.record(
        provider: provider.to_s,
        model: model,
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        metadata: metadata
      )
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
