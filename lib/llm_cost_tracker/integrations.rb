# frozen_string_literal: true

require_relative "errors"
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

    module_function

    def install!(names = LlmCostTracker.configuration.instrumented_integrations)
      normalize(names).each { |name| fetch(name).install }
    end

    def checks(names = LlmCostTracker.configuration.instrumented_integrations)
      return [Base::Result.new(:integrations, :ok, "no SDK integrations enabled")] if names.empty?

      normalize(names).map { |name| fetch(name).status }
    end

    def normalize(names)
      Array(names).flatten.uniq
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
