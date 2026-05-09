# frozen_string_literal: true

require_relative "errors"
require_relative "logging"
require_relative "integrations/openai"
require_relative "integrations/anthropic"
require_relative "integrations/ruby_llm"

module LlmCostTracker
  module Integrations
    AVAILABLE = {
      openai: Openai,
      anthropic: Anthropic,
      ruby_llm: RubyLlm
    }.freeze

    DOUBLE_INSTRUMENTATION_OVERLAPS = %i[openai anthropic].freeze

    module_function

    def install!(names = LlmCostTracker.configuration.instrumented_integrations)
      normalized = normalize(names)
      warn_double_instrumentation(normalized)
      normalized.each { |name| fetch(name).install }
    end

    def checks(names = LlmCostTracker.configuration.instrumented_integrations)
      return [Base::Result.new(:integrations, :ok, "no SDK integrations enabled")] if names.empty?

      normalize(names).map { |name| fetch(name).status }
    end

    def normalize(names)
      Array(names).flatten.uniq
    end

    def warn_double_instrumentation(names)
      return unless names.include?(:ruby_llm)

      overlapping = names & DOUBLE_INSTRUMENTATION_OVERLAPS
      return if overlapping.empty?

      Logging.warn(
        ":ruby_llm is enabled together with #{overlapping.map(&:inspect).join(', ')}. " \
        "RubyLLM uses HTTP underneath, so calls routed to those providers may be recorded twice " \
        "(once via the SDK patch, once via the Faraday parser). Pick one path per provider."
      )
    end

    def fetch(name)
      AVAILABLE.fetch(name) do
        message = "Unknown integration: #{name.inspect}. Use one of: #{names.join(', ')}"
        raise LlmCostTracker::Error, message
      end
    end

    def names
      AVAILABLE.keys
    end
  end
end
