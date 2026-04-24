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
          parser = coerce_parser(parser)

          MUTEX.synchronize do
            current = @parsers || default_parsers.freeze
            @parsers = ([parser] + current).freeze
          end

          parser
        end

        def find_for(url)
          parsers.find { |parser| parser.match?(url) }
        end

        def find_for_provider(provider)
          provider_name = provider.to_s.downcase
          parsers.find { |parser| provider_names_for(parser).include?(provider_name) }
        end

        def reset!
          MUTEX.synchronize { @parsers = nil }
        end

        private

        def coerce_parser(parser)
          return parser.new if parser.is_a?(Class) && parser <= Base
          return parser if parser.is_a?(Base)

          raise ArgumentError, "parser must be a LlmCostTracker::Parsers::Base instance or class"
        end

        def provider_names_for(parser)
          Array(parser.provider_names).map { |name| name.to_s.downcase }
        end

        def default_parsers
          [Openai.new, OpenaiCompatible.new, Anthropic.new, Gemini.new]
        end
      end
    end
  end
end
