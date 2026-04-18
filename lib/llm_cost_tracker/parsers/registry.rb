# frozen_string_literal: true

module LlmCostTracker
  module Parsers
    class Registry
      class << self
        PARSERS_MUTEX = Mutex.new

        def parsers
          @parsers || PARSERS_MUTEX.synchronize { @parsers ||= default_parsers }
        end

        def register(parser)
          PARSERS_MUTEX.synchronize { parsers.unshift(parser) }
        end

        def find_for(url)
          parsers.find { |p| p.match?(url) }
        end

        def reset!
          PARSERS_MUTEX.synchronize { @parsers = nil }
        end

        private

        def default_parsers
          [
            Openai.new,
            OpenaiCompatible.new,
            Anthropic.new,
            Gemini.new
          ]
        end
      end
    end
  end
end
