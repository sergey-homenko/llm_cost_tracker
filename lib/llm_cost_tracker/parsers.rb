# frozen_string_literal: true

module LlmCostTracker
  module Parsers
    BUILT_INS = [Openai.new, OpenaiCompatible.new, Anthropic.new, Gemini.new].freeze

    module_function

    def find_for(url)
      BUILT_INS.find { |parser| parser.match?(url) }
    end

    def find_for_provider(provider)
      provider_name = provider.to_s.downcase
      BUILT_INS.find do |parser|
        parser.provider_names.include?(provider_name)
      end
    end
  end
end
