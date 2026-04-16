# frozen_string_literal: true

module LlmCostTracker
  module Parsers
    class Registry
      class << self
        def parsers
          @parsers ||= [
            Openai.new,
            Anthropic.new,
            Gemini.new
          ]
        end

        def register(parser)
          parsers.unshift(parser)
        end

        def find_for(url)
          parsers.find { |p| p.match?(url) }
        end

        def reset!
          @parsers = nil
        end
      end
    end
  end
end
