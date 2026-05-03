# frozen_string_literal: true

require_relative "base"

module LlmCostTracker
  module Parsers
    class Anthropic < Base
      HOSTS = %w[api.anthropic.com].freeze

      def match?(url)
        match_uri?(url, hosts: HOSTS, path_includes: "/v1/messages")
      end

      def provider_names
        %w[anthropic]
      end

      def parse(request_body:, response_status:, response_body:, **)
        return nil unless response_status == 200

        response = safe_json_parse(response_body)
        usage    = response["usage"]
        return nil unless usage

        request = safe_json_parse(request_body)
        cache_read = usage["cache_read_input_tokens"].to_i

        UsageCapture.build(
          provider: "anthropic",
          provider_response_id: response["id"],
          pricing_mode: pricing_mode(request: request, response: response, usage: usage),
          model: response["model"] || request["model"],
          token_usage: token_usage(usage: usage, cache_read: cache_read),
          usage_source: :response,
          service_charges: service_charges(usage)
        )
      end

      def parse_stream(response_status:, request_body: nil, events: [], **)
        return nil unless response_status == 200

        request = safe_json_parse(request_body)
        model = find_event_value(events) { |data| data.dig("message", "model") } || request["model"]
        usage = stream_usage(events)
        response_id = find_event_value(events) { |data| data.dig("message", "id") || data["id"] }

        if usage
          build_stream_result(
            model: model,
            usage: usage,
            response_id: response_id,
            pricing_mode: pricing_mode(request: request, response: nil, usage: usage)
          )
        else
          build_unknown_stream_usage(
            provider: "anthropic",
            model: model,
            provider_response_id: response_id,
            pricing_mode: pricing_mode(request: request, response: nil, usage: usage)
          )
        end
      end

      private

      def stream_usage(events)
        start_usage = find_event_value(events, reverse: true) do |data|
          data.dig("message", "usage") if data["type"] == "message_start"
        end
        latest_delta = find_event_value(events, reverse: true) do |data|
          data["usage"] if data["type"] == "message_delta" && data["usage"].is_a?(Hash)
        end

        return nil unless start_usage || latest_delta

        (start_usage || {}).merge(latest_delta || {}) do |_key, start_val, delta_val|
          delta_val.nil? ? start_val : delta_val
        end
      end

      def build_stream_result(model:, usage:, response_id:, pricing_mode:)
        cache_read = usage["cache_read_input_tokens"].to_i

        UsageCapture.build(
          provider: "anthropic",
          provider_response_id: response_id,
          pricing_mode: pricing_mode,
          model: model,
          token_usage: token_usage(usage: usage, cache_read: cache_read),
          stream: true,
          usage_source: :stream_final,
          service_charges: service_charges(usage)
        )
      end

      def service_charges(usage)
        server_tool_use = usage["server_tool_use"]
        return [] unless server_tool_use.is_a?(Hash)

        [
          service_charge(
            component: :web_search_request,
            quantity: server_tool_use["web_search_requests"],
            source_key: "usage.server_tool_use.web_search_requests"
          ),
          service_charge(
            component: :code_execution_request,
            quantity: server_tool_use["code_execution_requests"],
            source_key: "usage.server_tool_use.code_execution_requests"
          )
        ].compact
      end

      def service_charge(component:, quantity:, source_key:)
        quantity = quantity.to_i
        return if quantity.zero?

        Billing::ServiceCharge.build(
          component: component,
          quantity: quantity,
          cost_status: Billing::CostStatus::UNKNOWN,
          pricing_basis: Billing::ServiceCharge::PROVIDER_USAGE_BASIS,
          source_key: source_key
        )
      end

      def token_usage(usage:, cache_read:)
        input = usage["input_tokens"].to_i
        output = usage["output_tokens"].to_i
        cache_creation = usage["cache_creation"]
        if cache_creation.is_a?(Hash)
          cache_write = cache_creation["ephemeral_5m_input_tokens"].to_i
          cache_write_1h = cache_creation["ephemeral_1h_input_tokens"].to_i
        else
          warn_unexpected_cache_creation(cache_creation, usage)
          cache_write = usage["cache_creation_input_tokens"].to_i
          cache_write_1h = 0
        end

        TokenUsage.build(
          input_tokens: input,
          output_tokens: output,
          total_tokens: input + output + cache_read + cache_write + cache_write_1h,
          cache_read_input_tokens: cache_read,
          cache_write_input_tokens: cache_write,
          cache_write_1h_input_tokens: cache_write_1h
        )
      end

      def warn_unexpected_cache_creation(cache_creation, usage)
        return if cache_creation.nil? || usage.key?("cache_creation_input_tokens")

        Logging.warn("Anthropic usage.cache_creation has unexpected shape: #{cache_creation.class}")
      end

      def pricing_mode(request:, response:, usage:)
        modes = []
        speed = usage&.fetch("speed", nil) || response&.fetch("speed", nil) || request["speed"]
        service_tier = usage&.fetch("service_tier", nil) ||
                       response&.fetch("service_tier", nil) ||
                       request["service_tier"]

        modes << Pricing.normalize_mode(speed)
        modes << Pricing.normalize_mode(service_tier)
        modes << "data_residency" if inference_geo(request: request, response: response, usage: usage) == "us"

        modes = modes.compact.uniq
        modes.empty? ? nil : modes.join("_")
      end

      def inference_geo(request:, response:, usage:)
        (
          usage&.fetch("inference_geo", nil) ||
          response&.fetch("inference_geo", nil) ||
          request["inference_geo"]
        ).to_s
      end
    end
  end
end
