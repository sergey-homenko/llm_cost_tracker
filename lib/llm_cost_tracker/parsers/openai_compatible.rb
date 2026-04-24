# frozen_string_literal: true

require_relative "base"
require_relative "openai_usage"

module LlmCostTracker
  module Parsers
    class OpenaiCompatible < Base
      include OpenaiUsage

      TRACKED_PATH_SUFFIXES = %w[/chat/completions /completions /embeddings /responses].freeze

      def match?(url)
        match_uri?(url, path_suffixes: TRACKED_PATH_SUFFIXES) { |uri| provider_for_uri(uri) }
      end

      def provider_names
        [
          "openai_compatible",
          *LlmCostTracker.configuration.openai_compatible_providers.each_value.map(&:to_s)
        ].uniq.freeze
      end

      def parse(request_url, request_body, response_status, response_body)
        parse_openai_usage(request_url, request_body, response_status, response_body)
      end

      def parse_stream(request_url, request_body, response_status, events)
        parse_openai_stream_usage(request_url, request_body, response_status, events)
      end

      private

      def provider_for(request_url)
        uri = parsed_uri(request_url)
        provider_for_uri(uri) || "openai_compatible"
      end

      def provider_for_uri(uri)
        return nil unless uri

        LlmCostTracker.configuration.openai_compatible_providers[uri.host.to_s.downcase]&.to_s
      end
    end
  end
end
