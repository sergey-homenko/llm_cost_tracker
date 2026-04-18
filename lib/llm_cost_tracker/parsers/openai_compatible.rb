# frozen_string_literal: true

require "uri"

require_relative "base"
require_relative "openai_usage"

module LlmCostTracker
  module Parsers
    class OpenaiCompatible < Base
      include OpenaiUsage

      TRACKED_PATH_SUFFIXES = %w[/chat/completions /completions /embeddings /responses].freeze

      def match?(url)
        uri = URI.parse(url.to_s)
        !provider_for_host(uri.host).nil? && tracked_path?(uri.path)
      rescue URI::InvalidURIError
        false
      end

      def parse(request_url, request_body, response_status, response_body)
        parse_openai_usage(request_url, request_body, response_status, response_body)
      end

      private

      def provider_for(request_url)
        uri = URI.parse(request_url.to_s)
        provider_for_host(uri.host) || "openai_compatible"
      rescue URI::InvalidURIError
        "openai_compatible"
      end

      def provider_for_host(host)
        configured_providers[host.to_s.downcase]&.to_s
      end

      def configured_providers
        LlmCostTracker.configuration.openai_compatible_providers
      end

      def tracked_path?(path)
        TRACKED_PATH_SUFFIXES.any? { |suffix| path == suffix || path.end_with?(suffix) }
      end
    end
  end
end
