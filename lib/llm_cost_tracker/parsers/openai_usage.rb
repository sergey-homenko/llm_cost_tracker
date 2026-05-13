# frozen_string_literal: true

require_relative "openai_service_charges"
require_relative "../providers/openai/hosts"
require_relative "../providers/openai/model_families"

module LlmCostTracker
  module Parsers
    module OpenaiUsage
      include OpenaiServiceCharges

      class << self
        def combined_pricing_mode(host:, model:, service_tier:)
          modes = [Pricing.normalize_mode(service_tier)]
          modes << "data_residency" if regional_processing?(host: host, model: model)
          modes = modes.compact.uniq
          modes.empty? ? nil : modes.join("_")
        end

        def regional_processing?(host:, model:)
          LlmCostTracker::Providers::Openai::Hosts.data_residency?(host) &&
            LlmCostTracker::Providers::Openai::ModelFamilies.data_residency?(model)
        end
      end

      private

      def parse_openai_usage(request_url:, request_body:, response_status:, response_body:)
        return nil unless response_status == 200

        response = safe_json_parse(response_body)
        usage = response["usage"]
        return nil unless usage

        request = safe_json_parse(request_body)
        cache_read = cache_read_input_tokens(usage)

        model = response["model"] || request["model"]

        UsageCapture.build(
          provider: provider_for(request_url),
          provider_response_id: response["id"],
          pricing_mode: pricing_mode(
            request_url: request_url,
            model: model,
            service_tier: response["service_tier"] || request["service_tier"]
          ),
          model: model,
          token_usage: token_usage(usage: usage, cache_read: cache_read, model: model),
          usage_source: :response,
          service_line_items: openai_service_line_items(response, request: request)
        )
      end

      def parse_openai_stream_usage(response_status:, request_url: nil, request_body: nil, events: [])
        return nil unless response_status == 200

        request = safe_json_parse(request_body)
        usage = detect_stream_usage(events)
        context = stream_capture_context(events: events, request: request, request_url: request_url)

        return build_known_stream_usage(usage: usage, **context) if usage

        warn_missing_stream_usage(request_url: request_url, request: request)
        build_unknown_stream_usage(**context)
      end

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
        cache_read = cache_read_input_tokens(usage)
        UsageCapture.build(
          provider: provider,
          provider_response_id: provider_response_id,
          pricing_mode: pricing_mode,
          model: model,
          token_usage: token_usage(usage: usage, cache_read: cache_read, model: model),
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
        find_event_value(events, reverse: true) do |data|
          usage = data["usage"] || data.dig("response", "usage") || data.dig("chunk", "usage")
          usage if usage.is_a?(Hash)
        end
      end

      def stream_pricing_mode(events)
        find_event_value(events, reverse: true) do |data|
          data["service_tier"] || data.dig("response", "service_tier") || data.dig("chunk", "service_tier")
        end
      end

      def pricing_mode(request_url:, model:, service_tier:)
        OpenaiUsage.combined_pricing_mode(host: parsed_uri(request_url)&.host, model: model, service_tier: service_tier)
      end

      def token_usage(usage:, cache_read:, model: nil)
        audio_input = audio_input_tokens(usage)
        audio_output = audio_output_tokens(usage)
        image_input = image_input_tokens(usage)
        image_output_details = image_output_tokens(usage)
        text_output_details = text_output_tokens(usage)
        raw_output = (usage["completion_tokens"] || usage["output_tokens"]).to_i
        image_output, regular_output_remainder = split_stream_image_output(
          raw_output: raw_output, image_output_details: image_output_details,
          text_output_details: text_output_details, audio_output: audio_output,
          default_to_image: LlmCostTracker::Providers::Openai::ModelFamilies.image_output?(model)
        )

        TokenUsage.build(
          input_tokens: regular_input_tokens(
            usage: usage, cache_read: cache_read, audio_input: audio_input, image_input: image_input
          ),
          output_tokens: regular_output_remainder,
          total_tokens: usage["total_tokens"],
          cache_read_input_tokens: cache_read,
          audio_input_tokens: audio_input,
          audio_output_tokens: audio_output,
          image_input_tokens: image_input,
          image_output_tokens: image_output,
          hidden_output_tokens: hidden_output_tokens(usage)
        )
      end

      def split_stream_image_output(raw_output:, image_output_details:, text_output_details:, audio_output:,
                                    default_to_image: false)
        if image_output_details.zero? && text_output_details.zero?
          remainder = [raw_output - audio_output, 0].max
          return default_to_image ? [remainder, 0] : [0, remainder]
        end

        text_output = text_output_details
        text_output = [raw_output - image_output_details - audio_output, 0].max if text_output.zero?
        [image_output_details, text_output]
      end

      def regular_input_tokens(usage:, cache_read:, audio_input:, image_input:)
        raw = (usage["prompt_tokens"] || usage["input_tokens"]).to_i
        [raw - cache_read - audio_input - image_input, 0].max
      end

      def cache_read_input_tokens(usage)
        details = input_token_details(usage)
        details["cached_tokens"].to_i
      end

      def audio_input_tokens(usage)
        details = input_token_details(usage)
        details["audio_tokens"].to_i
      end

      def hidden_output_tokens(usage)
        details = output_token_details(usage)
        details["reasoning_tokens"].to_i
      end

      def audio_output_tokens(usage)
        details = output_token_details(usage)
        details["audio_tokens"].to_i
      end

      def image_input_tokens(usage)
        details = input_token_details(usage)
        details["image_tokens"].to_i
      end

      def image_output_tokens(usage)
        details = output_token_details(usage)
        details["image_tokens"].to_i
      end

      def text_output_tokens(usage)
        details = output_token_details(usage)
        details["text_tokens"].to_i
      end

      def input_token_details(usage)
        usage["prompt_tokens_details"] || usage["input_tokens_details"] || usage["input_token_details"] || {}
      end

      def output_token_details(usage)
        usage["completion_tokens_details"] || usage["output_tokens_details"] || usage["output_token_details"] || {}
      end
    end
  end
end
