# frozen_string_literal: true

module LlmCostTracker
  module Parsers
    class Lookup
      PARSERS = [Openai.new, OpenaiCompatible.new, Anthropic.new, Gemini.new].freeze

      class << self
        def find_for(url)
          PARSERS.find { |parser| parser.match?(url) }
        end

        def find_for_provider(provider)
          provider_name = provider.to_s.downcase
          PARSERS.find do |parser|
            Array(parser.provider_names).map { |name| name.to_s.downcase }.include?(provider_name)
          end
        end
      end
    end
  end
end
