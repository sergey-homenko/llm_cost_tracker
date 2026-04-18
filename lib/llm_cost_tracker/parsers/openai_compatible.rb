# frozen_string_literal: true

require_relative "openai"

module LlmCostTracker
  module Parsers
    class OpenaiCompatible < Openai
      TRACKED_PATH_SUFFIXES = %w[/chat/completions /completions /embeddings /responses].freeze

      def match?(url)
        uri = URI.parse(url.to_s)
        !provider_for_host(uri.host).nil? && tracked_path?(uri.path)
      rescue URI::InvalidURIError
        false
      end

      private

      def provider_for(request_url)
        uri = URI.parse(request_url.to_s)
        provider_for_host(uri.host) || "openai_compatible"
      rescue URI::InvalidURIError
        "openai_compatible"
      end

      def provider_for_host(host)
        host = host.to_s.downcase
        provider_name = configured_providers[host] ||
                        configured_providers.find do |configured_host, _provider|
                          configured_host.to_s.downcase == host
                        end&.last
        provider_name&.to_s
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
