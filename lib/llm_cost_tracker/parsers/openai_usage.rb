# frozen_string_literal: true

require "active_support/core_ext/hash/keys"

require_relative "../providers/openai/hosts"
require_relative "../providers/openai/model_families"
require_relative "../providers/openai/service_charges"
require_relative "../providers/openai/usage_extractor"

module LlmCostTracker
  module Parsers
    module OpenaiUsage
      include LlmCostTracker::Providers::Openai::ServiceCharges

      class << self
        def combined_pricing_mode(host:, model:, service_tier:)
          modes = [Pricing::Mode.normalize(service_tier)]
          modes << "data_residency" if regional_processing?(host: host, model: model)
          modes = modes.compact.uniq
          modes.empty? ? nil : modes.join("_")
        end

        def regional_processing?(host:, model:)
          LlmCostTracker::Providers::Openai::Hosts.data_residency?(host) &&
            LlmCostTracker::Providers::Openai::ModelFamilies.data_residency?(model)
        end
      end

      def parse(request_url:, request_body:, response_status:, response_body:, **)
        return nil unless response_status == 200

        response = safe_json_parse(response_body)
        usage = response["usage"]&.deep_symbolize_keys
        return nil unless usage

        request = safe_json_parse(request_body)
        model = response["model"] || request["model"]

        Event.build(
          provider: provider_for(request_url),
          provider_response_id: response["id"],
          pricing_mode: pricing_mode(
            request_url: request_url,
            model: model,
            service_tier: response["service_tier"] || request["service_tier"]
          ),
          model: model,
          token_usage: LlmCostTracker::Providers::Openai::UsageExtractor.token_usage(usage, model: model),
          usage_source: :response,
          service_line_items: service_line_items_for(response, request: request, model: response["model"])
        )
      end

      def parse_stream(response_status:, request_url: nil, request_body: nil, events: [], **)
        return nil unless response_status == 200

        request = safe_json_parse(request_body)
        usage = detect_stream_usage(events)
        context = stream_capture_context(events: events, request: request, request_url: request_url)

        return build_known_stream_usage(usage: usage, **context) if usage

        warn_missing_stream_usage(request_url: request_url, request: request)
        build_unknown_stream_usage(**context)
      end

      def auto_enable_stream_usage?(request_url)
        openai_chat_completions_url?(request_url)
      end

      private

      def stream_capture_context(events:, request:, request_url:)
        model = find_event_value(events) do |data|
          data["model"] || data.dig("response", "model") || data.dig("chunk", "model")
        end || request["model"]
        {
          provider: provider_for(request_url),
          model: model,
          provider_response_id: find_event_value(events) do |data|
            data["id"] || data.dig("response", "id") || data.dig("chunk", "id")
          end,
          pricing_mode: pricing_mode(
            request_url: request_url,
            model: model,
            service_tier: stream_pricing_mode(events) || request["service_tier"]
          ),
          service_line_items: openai_stream_service_line_items(events, request: request, model: model)
        }
      end

      def build_known_stream_usage(usage:, provider:, model:, provider_response_id:, pricing_mode:, service_line_items:)
        Event.build(
          provider: provider,
          provider_response_id: provider_response_id,
          pricing_mode: pricing_mode,
          model: model,
          token_usage: LlmCostTracker::Providers::Openai::UsageExtractor.token_usage(usage, model: model),
          stream: true,
          usage_source: :stream_final,
          service_line_items: service_line_items
        )
      end

      def warn_missing_stream_usage(request_url:, request:)
        return unless request.is_a?(Hash) && request["stream"]
        return unless openai_chat_completions_url?(request_url)
        return if request.dig("stream_options", "include_usage")

        Logging.warn(
          "OpenAI-compatible chat-completions stream finished without a final usage chunk. " \
          "Set `stream_options: { include_usage: true }` in your request body so the gem can " \
          "record token counts. This call was stored with usage_source=unknown."
        )
      end

      def openai_chat_completions_url?(request_url)
        uri = parsed_uri(request_url)
        uri && uri.path.to_s.end_with?("/chat/completions")
      end

      def detect_stream_usage(events)
        usage = find_event_value(events, reverse: true) do |data|
          candidate = data["usage"] || data.dig("response", "usage") || data.dig("chunk", "usage")
          candidate if candidate.is_a?(Hash)
        end
        usage&.deep_symbolize_keys
      end

      def stream_pricing_mode(events)
        find_event_value(events, reverse: true) do |data|
          data["service_tier"] || data.dig("response", "service_tier") || data.dig("chunk", "service_tier")
        end
      end

      def pricing_mode(request_url:, model:, service_tier:)
        OpenaiUsage.combined_pricing_mode(host: parsed_uri(request_url)&.host, model: model, service_tier: service_tier)
      end
    end
  end
end
