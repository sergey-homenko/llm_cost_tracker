# frozen_string_literal: true

require_relative "../billing/line_item"
require_relative "base"

module LlmCostTracker
  module Parsers
    class Gemini < Base
      HOSTS = %w[generativelanguage.googleapis.com].freeze
      TRACKED_PATH_PATTERN = %r{/models/[^/:]+:(?:generateContent|streamGenerateContent)\z}
      STREAM_PATH_PATTERN  = /:streamGenerateContent\z/
      PER_QUERY_GROUNDING_MODEL_PATTERN = /\bgemini-(?:[3-9]|[1-9]\d)\b/i

      def match?(url)
        match_uri?(url, hosts: HOSTS, path_pattern: TRACKED_PATH_PATTERN)
      end

      def provider_names
        %w[gemini]
      end

      def streaming_request?(request_url, request_body)
        return true if match_uri?(request_url, path_pattern: STREAM_PATH_PATTERN)

        super
      end

      def parse(request_url:, request_body:, response_status:, response_body:, response_headers: nil)
        return nil unless response_status == 200

        response = safe_json_parse(response_body)
        usage    = response["usageMetadata"]
        return nil unless usage

        request = safe_json_parse(request_body)
        model = extract_model_from_url(request_url)
        build_usage_capture(
          request_url: request_url,
          usage: usage,
          usage_source: :response,
          provider_response_id: response["responseId"],
          pricing_mode: pricing_mode(request: request, response_headers: response_headers),
          service_line_items: grounding_line_items_for_response(response, model: model)
        )
      end

      def parse_stream(response_status:, request_url: nil, request_body: nil, events: [], response_headers: nil)
        return nil unless response_status == 200

        request = safe_json_parse(request_body)
        usage = merged_stream_usage(events)
        model = extract_model_from_url(request_url)
        response_id = stream_response_id(events)
        mode = pricing_mode(request: request, response_headers: response_headers)
        service_line_items = grounding_line_items_for_stream(events, model: model)

        if usage
          build_usage_capture(
            request_url: request_url,
            usage: usage,
            stream: true,
            usage_source: :stream_final,
            provider_response_id: response_id,
            pricing_mode: mode,
            service_line_items: service_line_items
          )
        else
          build_unknown_stream_usage(
            provider: "gemini",
            model: model,
            provider_response_id: response_id,
            pricing_mode: mode,
            service_line_items: service_line_items
          )
        end
      end

      private

      def provider_for(_request_url)
        "gemini"
      end

      def build_usage_capture(request_url:, usage:, usage_source:, stream: false, provider_response_id: nil,
                              pricing_mode: nil, service_line_items: nil)
        cache_read = usage["cachedContentTokenCount"].to_i
        tool_use_prompt = usage["toolUsePromptTokenCount"].to_i
        audio_input = audio_input_tokens(usage)
        audio_output = audio_output_tokens(usage)

        UsageCapture.build(
          provider: "gemini",
          model: extract_model_from_url(request_url),
          pricing_mode: pricing_mode,
          token_usage: TokenUsage.build(
            input_tokens: regular_input_tokens(usage: usage, cache_read: cache_read, audio_input: audio_input) +
                          tool_use_prompt,
            output_tokens: regular_output_tokens(usage: usage, audio_output: audio_output),
            total_tokens: usage["totalTokenCount"],
            cache_read_input_tokens: cache_read,
            audio_input_tokens: audio_input,
            audio_output_tokens: audio_output,
            hidden_output_tokens: usage["thoughtsTokenCount"]
          ),
          stream: stream,
          usage_source: usage_source,
          provider_response_id: provider_response_id,
          service_line_items: service_line_items
        )
      end

      def merged_stream_usage(events)
        find_event_value(events, reverse: true) do |data|
          meta = data["usageMetadata"]
          meta if meta.is_a?(Hash)
        end
      end

      def output_tokens(usage)
        (usage["candidatesTokenCount"] || usage["responseTokenCount"]).to_i + usage["thoughtsTokenCount"].to_i
      end

      def regular_input_tokens(usage:, cache_read:, audio_input:)
        [usage["promptTokenCount"].to_i - cache_read - audio_input, 0].max
      end

      def regular_output_tokens(usage:, audio_output:)
        [output_tokens(usage) - audio_output, 0].max
      end

      def audio_input_tokens(usage)
        prompt_audio = modality_tokens(usage["promptTokensDetails"] || usage["prompt_tokens_details"], "AUDIO")
        cache_audio = modality_tokens(usage["cacheTokensDetails"] || usage["cache_tokens_details"], "AUDIO")
        [prompt_audio - cache_audio, 0].max
      end

      def audio_output_tokens(usage)
        modality_tokens(
          usage["candidatesTokensDetails"] ||
            usage["candidates_tokens_details"] ||
            usage["responseTokensDetails"] ||
            usage["response_tokens_details"],
          "AUDIO"
        )
      end

      def modality_tokens(details, modality)
        Array(details).sum do |detail|
          next 0 unless detail.is_a?(Hash)

          next 0 unless detail["modality"] == modality

          (detail["tokenCount"] || detail["token_count"]).to_i
        end
      end

      def stream_response_id(events)
        find_event_value(events) { |data| data["responseId"] }
      end

      def extract_model_from_url(url)
        uri = parsed_uri(url)
        return nil unless uri

        match = uri.path.match(%r{/models/([^/:]+)})
        match && match[1]
      end

      def pricing_mode(request:, response_headers:)
        response_tier = response_header(response_headers, "x-gemini-service-tier")
        response_mode = Pricing.normalize_mode(response_tier)
        return response_mode if response_mode

        request_mode = Pricing.normalize_mode(
          request["service_tier"] ||
          request["serviceTier"] ||
          request.dig("config", "service_tier") ||
          request.dig("config", "serviceTier")
        )
        request_mode == :flex ? request_mode : nil
      end

      def response_header(headers, name)
        headers.to_h.find { |key, _value| key.to_s.downcase == name }&.last
      end

      def grounding_line_items_for_response(response, model:)
        grounding_line_items(grounding_request_count(response["candidates"]), model: model)
      end

      def grounding_line_items_for_stream(events, model:)
        quantity = find_event_value(events, reverse: true) do |data|
          count = grounding_request_count(data["candidates"])
          count if count.positive?
        end
        grounding_line_items(quantity || 0, model: model)
      end

      def grounding_request_count(candidates)
        Array(candidates).sum do |candidate|
          next 0 unless candidate.is_a?(Hash)

          metadata = candidate["groundingMetadata"] || candidate["grounding_metadata"] || {}
          queries = metadata["webSearchQueries"] || metadata["web_search_queries"] || []
          Array(queries).size
        end
      end

      def grounding_line_items(query_count, model:)
        return [] unless query_count.positive?

        billed_quantity = grounding_billed_quantity(query_count, model: model)
        [
          Billing::LineItem.build(
            component_key: :grounding_request,
            quantity: billed_quantity,
            cost_status: Billing::CostStatus::UNKNOWN,
            pricing_basis: :provider_usage,
            provider_field: "response.candidates.groundingMetadata.webSearchQueries",
            details: { web_search_queries: query_count }
          )
        ]
      end

      def grounding_billed_quantity(query_count, model:)
        per_query_billing?(model) ? query_count : 1
      end

      def per_query_billing?(model)
        model.to_s.match?(PER_QUERY_GROUNDING_MODEL_PATTERN)
      end
    end
  end
end
