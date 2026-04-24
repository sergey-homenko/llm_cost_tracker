# frozen_string_literal: true

require_relative "base"
require_relative "openai_usage"

module LlmCostTracker
  module Parsers
    class OpenaiCompatible < Base
      include OpenaiUsage

      TRACKED_PATH_SUFFIXES = %w[/chat/completions /completions /embeddings /responses].freeze

      def match?(url)
        uri_matches?(url) { |uri| !provider_for_host(uri.host).nil? && tracked_path?(uri.path) }
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
        return "openai_compatible" unless uri

        provider_for_host(uri.host) || "openai_compatible"
      end

      def provider_for_host(host)
        LlmCostTracker.configuration.openai_compatible_providers[host.to_s.downcase]&.to_s
      end

      def tracked_path?(path)
        TRACKED_PATH_SUFFIXES.any? { |suffix| path == suffix || path.end_with?(suffix) }
      end
    end
  end
end
