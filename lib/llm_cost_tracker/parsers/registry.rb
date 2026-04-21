# frozen_string_literal: true

module LlmCostTracker
  module Parsers
    class Registry
      class << self
        def parsers
          @parsers ||= default_parsers
        end

        def register(parser)
          parsers.unshift(parser)
        end

        def find_for(url)
          parsers.find { |parser| parser.match?(url) }
        end

        def find_for_provider(provider)
          provider_name = provider.to_s
          parsers.find { |parser| parser.provider_names.include?(provider_name) }
        end

        def reset!
          @parsers = nil
        end

        private

        def default_parsers
          [Openai.new, OpenaiCompatible.new, Anthropic.new, Gemini.new]
        end
      end
    end
  end
end
