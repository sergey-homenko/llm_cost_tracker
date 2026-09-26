# frozen_string_literal: true

module LlmCostTracker
  module Providers
    module Openai
      class Parser < LlmCostTracker::Parsers::Base
        include ResponseParser

        TRACKED_ENDPOINTS = %w[
          chat/completions completions embeddings moderations responses
          audio/transcriptions audio/translations audio/speech
          images/generations images/edits images/variations
        ].freeze
        TRACKED_PATHS = TRACKED_ENDPOINTS.map { |endpoint| "/v1/#{endpoint}" }.freeze

        class << self
          def match?(url)
            uri_matches?(url) do |uri|
              Hosts::API_HOSTS.include?(uri.host.to_s.downcase) && TRACKED_PATHS.include?(uri.path.to_s)
            end
          end

          def provider_names
            %w[openai]
          end
        end

        def provider_for(_request_url)
          "openai"
        end
      end
    end
  end
end
