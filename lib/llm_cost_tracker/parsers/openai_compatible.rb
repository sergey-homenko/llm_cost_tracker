# frozen_string_literal: true

require_relative "base"
require_relative "openai_usage"

module LlmCostTracker
  module Parsers
    class OpenaiCompatible < Base
      include OpenaiUsage

      TRACKED_PATH_SUFFIXES = %w[/chat/completions /completions /embeddings /responses].freeze

      class << self
        def match?(url)
          match_uri?(url, path_suffixes: TRACKED_PATH_SUFFIXES) { |uri| provider_for_uri(uri) }
        end

        def provider_names
          providers = LlmCostTracker.configuration.openai_compatible_providers
          cached = @provider_names
          return cached if cached && @provider_names_providers.equal?(providers)

          names = [
            "openai_compatible",
            *providers.each_value.map { |provider| provider.to_s.downcase }
          ].uniq.freeze
          return names unless providers.frozen?

          @provider_names_providers = providers
          @provider_names = names
        end

        def provider_for_uri(uri)
          return nil unless uri

          LlmCostTracker.configuration.openai_compatible_providers[uri.host.to_s.downcase]&.to_s
        end
      end

      def provider_for(request_url)
        self.class.provider_for_uri(parsed_uri(request_url)) || "openai_compatible"
      end
    end
  end
end
