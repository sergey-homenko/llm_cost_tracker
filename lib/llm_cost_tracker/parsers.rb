# frozen_string_literal: true

require_relative "parsers/base"
require_relative "providers"

module LlmCostTracker
  module Parsers
    MUTEX = Mutex.new
    PARSER_PROVIDERS = %i[Openai Azure OpenaiCompatible Anthropic Gemini].freeze

    module_function

    def find_for(url)
      parser_classes.each do |klass|
        return instance_for(klass) if klass.match?(url)
      end
      nil
    end

    def find_for_provider(provider)
      provider_name = provider.to_s.downcase
      parser_classes.each do |klass|
        return instance_for(klass) if klass.provider_names.include?(provider_name)
      end
      nil
    end

    def parser_classes
      PARSER_PROVIDERS.map { |name| Providers.const_get(name)::Parser }
    end
    private_class_method :parser_classes

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
