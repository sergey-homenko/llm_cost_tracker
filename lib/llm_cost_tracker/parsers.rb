# frozen_string_literal: true

module LlmCostTracker
  module Parsers
    autoload :Base,                 "llm_cost_tracker/parsers/base"
    autoload :OpenaiUsage,          "llm_cost_tracker/parsers/openai_usage"
    autoload :OpenaiServiceCharges, "llm_cost_tracker/parsers/openai_service_charges"
    autoload :SSE,                  "llm_cost_tracker/parsers/sse"
    autoload :Openai,               "llm_cost_tracker/parsers/openai"
    autoload :Azure,                "llm_cost_tracker/parsers/azure"
    autoload :OpenaiCompatible,     "llm_cost_tracker/parsers/openai_compatible"
    autoload :Anthropic,            "llm_cost_tracker/parsers/anthropic"
    autoload :Gemini,               "llm_cost_tracker/parsers/gemini"

    MUTEX = Mutex.new
    PARSER_CONSTANTS = %i[Openai Azure OpenaiCompatible Anthropic Gemini].freeze

    module_function

    def find_for(url)
      PARSER_CONSTANTS.each do |name|
        klass = const_get(name)
        return instance_for(klass) if klass.match?(url)
      end
      nil
    end

    def find_for_provider(provider)
      provider_name = provider.to_s.downcase
      PARSER_CONSTANTS.each do |name|
        klass = const_get(name)
        return instance_for(klass) if klass.provider_names.include?(provider_name)
      end
      nil
    end

    def instance_for(klass)
      cached = (@instances ||= {})[klass]
      return cached if cached

      MUTEX.synchronize do
        @instances[klass] ||= klass.new
      end
    end
    private_class_method :instance_for
  end
end
