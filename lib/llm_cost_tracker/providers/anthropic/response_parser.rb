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
                                  stream: false,
                                  stop_reason: nil,
                                  refusal_category: nil,
                                  content: nil,
                                  host: nil)
          model = UsageExtractor.served_model(usage, content) || model
          pricing_mode = UsageExtractor.pricing_mode(request: request, usage: usage, host: host, model: model)
          line_items = UsageExtractor.service_line_items(usage) +
                       UsageExtractor.iteration_line_items(usage, content: content) +
                       UsageExtractor.refusal_line_items(usage, stop_reason:, refusal_category:)
          Event.build(
            provider: "anthropic",
            provider_response_id: provider_response_id,
            pricing_mode: pricing_mode,
            model: model,
            token_usage: UsageExtractor.token_usage(usage),
            stream: stream,
            usage_source: usage_source,
            service_line_items: line_items
          )
        end
      end
    end
  end
end
