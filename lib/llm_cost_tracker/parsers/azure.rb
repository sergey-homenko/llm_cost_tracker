# frozen_string_literal: true

require_relative "base"
require_relative "openai_usage"
require_relative "../providers/azure/hosts"

module LlmCostTracker
  module Parsers
    class Azure < Base
      include OpenaiUsage

      PATH_PATTERN = %r{
        \A/openai/deployments/[^/]+/
        (chat/completions|completions|embeddings|audio/transcriptions|audio/translations|images/generations)\z
      }x

      class << self
        def match?(url)
          uri_matches?(url) do |uri|
            LlmCostTracker::Providers::Azure::Hosts.openai?(uri.host) && uri.path.to_s.match?(PATH_PATTERN)
          end
        end

        def provider_names
          %w[azure_openai]
        end
      end

      def provider_for(_request_url)
        "azure_openai"
      end

      def model_for(request_url, request_parsed)
        body_model = super
        return body_model if body_model

        uri = parsed_uri(request_url)
        match = uri&.path&.match(%r{/openai/deployments/([^/]+)/})
        match && match[1]
      end
    end
  end
end
