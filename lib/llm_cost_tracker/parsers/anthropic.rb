# frozen_string_literal: true

require_relative "base"

module LlmCostTracker
  module Parsers
    class Anthropic < Base
      HOSTS = %w[api.anthropic.com].freeze

      class << self
        def match?(url)
          match_uri?(url, hosts: HOSTS, path_includes: "/v1/messages")
        end

        def provider_names
          %w[anthropic]
        end
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
          service_line_items: service_line_items(usage)
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

      def provider_for(_request_url)
        "anthropic"
      end

      DATA_RESIDENCY_GEOS = %w[us].freeze
      STANDARD_EQUIVALENT_SERVICE_TIERS = %w[standard standard_only priority].freeze
      private_constant :DATA_RESIDENCY_GEOS, :STANDARD_EQUIVALENT_SERVICE_TIERS

      private

      def stream_usage(events)
        latest_delta = find_event_value(events, reverse: true) do |data|
          data["usage"] if data["type"] == "message_delta" && data["usage"].is_a?(Hash)
        end
        return nil unless latest_delta

        start_usage = find_event_value(events, reverse: true) do |data|
          data.dig("message", "usage") if data["type"] == "message_start"
        end

        (start_usage || {}).merge(latest_delta) do |_key, start_val, delta_val|
          delta_val || start_val
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
          service_line_items: service_line_items(usage)
        )
      end

      def service_line_items(usage)
        server_tool_use = usage["server_tool_use"]
        return [] unless server_tool_use.is_a?(Hash)

        [
          service_line_item(
            component_key: :web_search_request,
            quantity: server_tool_use["web_search_requests"],
            provider_field: "usage.server_tool_use.web_search_requests"
          ),
          service_line_item(
            component_key: :web_fetch_request,
            quantity: server_tool_use["web_fetch_requests"],
            provider_field: "usage.server_tool_use.web_fetch_requests"
          ),
          service_line_item(
            component_key: :code_execution_request,
            quantity: server_tool_use["code_execution_requests"],
            provider_field: "usage.server_tool_use.code_execution_requests"
          )
        ].compact
      end

      def service_line_item(component_key:, quantity:, provider_field:)
        quantity = quantity.to_i
        return if quantity.zero?

        Billing::LineItem.build(
          component_key: component_key,
          quantity: quantity,
          cost_status: Billing::CostStatus::UNKNOWN,
          pricing_basis: :provider_usage,
          provider_field: provider_field
        )
      end

      def token_usage(usage:, cache_read:)
        input = usage["input_tokens"].to_i
        output = usage["output_tokens"].to_i
        cache_creation = usage["cache_creation"]
        if cache_creation.is_a?(Hash)
          cache_write = cache_creation["ephemeral_5m_input_tokens"].to_i
          cache_write_extended = cache_creation["ephemeral_1h_input_tokens"].to_i
        else
          warn_unexpected_cache_creation(cache_creation, usage)
          cache_write = usage["cache_creation_input_tokens"].to_i
          cache_write_extended = 0
        end
        hidden_output = (
          usage["thinking_tokens"] || usage["thinking_output_tokens"] ||
            usage.dig("output_tokens_details", "reasoning_tokens")
        ).to_i

        TokenUsage.build(
          input_tokens: input,
          output_tokens: output,
          total_tokens: input + output + cache_read + cache_write + cache_write_extended,
          cache_read_input_tokens: cache_read,
          cache_write_input_tokens: cache_write,
          cache_write_extended_input_tokens: cache_write_extended,
          hidden_output_tokens: hidden_output
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
        service_tier = nil if STANDARD_EQUIVALENT_SERVICE_TIERS.include?(service_tier.to_s)

        modes << Pricing.normalize_mode(speed)
        modes << Pricing.normalize_mode(service_tier)
        geo = inference_geo(request: request, response: response, usage: usage).downcase
        modes << "data_residency" if DATA_RESIDENCY_GEOS.include?(geo)

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
