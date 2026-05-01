# frozen_string_literal: true

require_relative "openai_service_charges"

module LlmCostTracker
  module Parsers
    module OpenaiUsage
      include OpenaiServiceCharges

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
          service_charges: openai_service_charges(response)
        )
      end

      def parse_openai_stream_usage(response_status:, request_url: nil, request_body: nil, events: [])
        return nil unless response_status == 200

        request = safe_json_parse(request_body)
        model = find_event_value(events) { |data| data["model"] || data.dig("response", "model") } || request["model"]
        usage = detect_stream_usage(events)
        response_id = find_event_value(events) { |data| data["id"] || data.dig("response", "id") }
        pricing_mode = pricing_mode(
          request_url: request_url,
          model: model,
          service_tier: stream_pricing_mode(events) || request["service_tier"]
        )
        service_charges = openai_stream_service_charges(events)

        if usage
          cache_read = cache_read_input_tokens(usage)
          UsageCapture.build(
            provider: provider_for(request_url),
            provider_response_id: response_id,
            pricing_mode: pricing_mode,
            model: model,
            token_usage: token_usage(usage: usage, cache_read: cache_read),
            stream: true,
            usage_source: :stream_final,
            service_charges: service_charges
          )
        else
          build_unknown_stream_usage(
            provider: provider_for(request_url),
            model: model,
            provider_response_id: response_id,
            pricing_mode: pricing_mode,
            service_charges: service_charges
          )
        end
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
        return false unless %w[us.api.openai.com eu.api.openai.com].include?(uri&.host.to_s.downcase)

        openai_data_residency_model?(model)
      end

      def openai_data_residency_model?(model)
        model.to_s.match?(/\Agpt-5\.(?:4|5)(?:-(?:mini|nano|pro))?(?:-\d{4}-\d{2}-\d{2})?\z/)
      end

      def token_usage(usage:, cache_read:)
        TokenUsage.build(
          input_tokens: regular_input_tokens(usage: usage, cache_read: cache_read),
          output_tokens: (usage["completion_tokens"] || usage["output_tokens"]).to_i,
          total_tokens: total_tokens(usage: usage, cache_read: cache_read),
          cache_read_input_tokens: cache_read,
          hidden_output_tokens: hidden_output_tokens(usage)
        )
      end

      def regular_input_tokens(usage:, cache_read:)
        [(usage["prompt_tokens"] || usage["input_tokens"]).to_i - cache_read.to_i, 0].max
      end

      def cache_read_input_tokens(usage)
        details = usage["prompt_tokens_details"] || usage["input_tokens_details"] || {}
        details["cached_tokens"]
      end

      def hidden_output_tokens(usage)
        details = usage["completion_tokens_details"] || usage["output_tokens_details"] || {}
        details["reasoning_tokens"]
      end

      def total_tokens(usage:, cache_read:)
        total = usage["total_tokens"]
        return total.to_i unless total.nil?

        regular_input_tokens(usage: usage, cache_read: cache_read) +
          cache_read.to_i +
          (usage["completion_tokens"] || usage["output_tokens"]).to_i
      end
    end
  end
end
