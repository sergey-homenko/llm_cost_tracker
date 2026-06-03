# frozen_string_literal: true

require_relative "usage_extractor"

module LlmCostTracker
  module Providers
    module Anthropic
      module ResponseParser
        def self.event_from_usage(usage:,
                                  model:,
                                  provider_response_id:,
                                  usage_source:,
                                  request: nil,
                                  pricing_mode: nil,
                                  stream: false)
          Event.build(
            provider: "anthropic",
            provider_response_id: provider_response_id,
            pricing_mode: pricing_mode || UsageExtractor.pricing_mode(request: request, usage: usage),
            model: model,
            token_usage: UsageExtractor.token_usage(usage),
            stream: stream,
            usage_source: usage_source,
            service_line_items: UsageExtractor.service_line_items(usage)
          )
        end
      end
    end
  end
end
