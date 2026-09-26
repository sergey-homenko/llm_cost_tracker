# frozen_string_literal: true

module LlmCostTracker
  module Providers
    module OpenaiCompatible
      class Parser < LlmCostTracker::Parsers::Base
        include Openai::ResponseParser

        TRACKED_PATH_SUFFIXES = %w[/chat/completions /completions /embeddings /responses].freeze

        class << self
          def match?(url)
            uri_matches?(url) do |uri|
              TRACKED_PATH_SUFFIXES.any? { |suffix| uri.path.to_s.end_with?(suffix) } && !provider_for_uri(uri).nil?
            end
          end

          def provider_names
            custom = LlmCostTracker.configuration.capture.openai_compatible_providers.each_value.map do |provider|
              provider.to_s.downcase
            end
            ["openai_compatible", *custom].uniq
          end

          def provider_for_uri(uri)
            return nil unless uri

            LlmCostTracker.configuration.capture.openai_compatible_providers[uri.host.to_s.downcase]&.to_s
          end
        end

        def provider_for(request_url)
          self.class.provider_for_uri(parsed_uri(request_url)) || "openai_compatible"
        end

        def auto_enable_stream_usage?(request_url, request_parsed)
          super && Configuration::Capture::OPENAI_COMPATIBLE_PROVIDERS.key?(parsed_uri(request_url).host.to_s.downcase)
        end
      end
    end
  end
end
