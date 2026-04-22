# frozen_string_literal: true

require "monitor"

module LlmCostTracker
  module Parsers
    class Registry
      MUTEX = Monitor.new

      class << self
        def parsers
          @parsers || MUTEX.synchronize { @parsers ||= default_parsers.freeze }
        end

        def register(parser)
          MUTEX.synchronize do
            current = @parsers || default_parsers.freeze
            @parsers = ([parser] + current).freeze
          end
        end

        def find_for(url)
          parsers.find { |parser| parser.match?(url) }
        end

        def find_for_provider(provider)
          provider_name = provider.to_s
          parsers.find { |parser| parser.provider_names.include?(provider_name) }
        end

        def reset!
          MUTEX.synchronize { @parsers = nil }
        end

        private

        def default_parsers
          [Openai.new, OpenaiCompatible.new, Anthropic.new, Gemini.new]
        end
      end
    end
  end
end
