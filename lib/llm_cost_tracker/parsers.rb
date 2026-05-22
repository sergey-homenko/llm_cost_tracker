# frozen_string_literal: true

require_relative "parsers/base"
require_relative "providers/openai/parser"
require_relative "providers/azure/parser"
require_relative "providers/openai_compatible/parser"
require_relative "providers/anthropic/parser"
require_relative "providers/gemini/parser"

module LlmCostTracker
  module Parsers
    MUTEX = Mutex.new
    PARSER_CLASSES = [
      Providers::Openai::Parser,
      Providers::Azure::Parser,
      Providers::OpenaiCompatible::Parser,
      Providers::Anthropic::Parser,
      Providers::Gemini::Parser
    ].freeze

    module_function

    def find_for(url)
      PARSER_CLASSES.each do |klass|
        return instance_for(klass) if klass.match?(url)
      end
      nil
    end

    def find_for_provider(provider)
      provider_name = provider.to_s.downcase
      PARSER_CLASSES.each do |klass|
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
