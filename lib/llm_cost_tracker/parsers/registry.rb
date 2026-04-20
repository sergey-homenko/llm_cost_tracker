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
