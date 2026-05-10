# frozen_string_literal: true

require_relative "openai_service_charges"

module LlmCostTracker
  module Parsers
    module OpenaiUsage
      include OpenaiServiceCharges

      OPENAI_DATA_RESIDENCY_HOST_PATTERN = /\A[a-z]{2,3}\.api\.openai\.com\z/

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
          token_usage: token_usage(usage: usage, cache_read: cache_read),
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
        model = find_event_value(events) { |data| data["model"] || data.dig("response", "model") } || request["model"]
        {
          provider: provider_for(request_url),
          model: model,
          provider_response_id: find_event_value(events) { |data| data["id"] || data.dig("response", "id") },
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
          token_usage: token_usage(usage: usage, cache_read: cache_read),
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
          usage = data["usage"] || data.dig("response", "usage")
          usage if usage.is_a?(Hash)
        end
      end

      def stream_pricing_mode(events)
        find_event_value(events, reverse: true) do |data|
          data["service_tier"] || data.dig("response", "service_tier")
        end
      end

      def pricing_mode(request_url:, model:, service_tier:)
        modes = [Pricing.normalize_mode(service_tier)]
        modes << "data_residency" if openai_regional_processing?(request_url: request_url, model: model)
        modes = modes.compact.uniq
        modes.empty? ? nil : modes.join("_")
      end

      def openai_regional_processing?(request_url:, model:)
        uri = parsed_uri(request_url)
        return false unless uri&.host.to_s.downcase.match?(OPENAI_DATA_RESIDENCY_HOST_PATTERN)

        openai_data_residency_model?(model)
      end

      def openai_data_residency_model?(model)
        model.to_s.match?(/\Agpt-5\.(?:4|5)(?:-(?:mini|nano|pro))?(?:-\d{4}-\d{2}-\d{2})?\z/)
      end

      def token_usage(usage:, cache_read:)
        audio_input = audio_input_tokens(usage)
        audio_output = audio_output_tokens(usage)

        TokenUsage.build(
          input_tokens: regular_input_tokens(usage: usage, cache_read: cache_read, audio_input: audio_input),
          output_tokens: regular_output_tokens(usage: usage, audio_output: audio_output),
          total_tokens: usage["total_tokens"],
          cache_read_input_tokens: cache_read,
          audio_input_tokens: audio_input,
          audio_output_tokens: audio_output,
          hidden_output_tokens: hidden_output_tokens(usage)
        )
      end

      def regular_input_tokens(usage:, cache_read:, audio_input:)
        [(usage["prompt_tokens"] || usage["input_tokens"]).to_i - cache_read - audio_input, 0].max
      end

      def regular_output_tokens(usage:, audio_output:)
        [(usage["completion_tokens"] || usage["output_tokens"]).to_i - audio_output, 0].max
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

      def input_token_details(usage)
        usage["prompt_tokens_details"] || usage["input_tokens_details"] || usage["input_token_details"] || {}
      end

      def output_token_details(usage)
        usage["completion_tokens_details"] || usage["output_tokens_details"] || usage["output_token_details"] || {}
      end
    end
  end
end
