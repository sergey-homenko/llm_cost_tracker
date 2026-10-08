# frozen_string_literal: true

require "bigdecimal"
require "time"

module LlmCostTracker
  module Providers
    module Gemini
      class Parser < LlmCostTracker::Parsers::Base
        HOSTS = %w[generativelanguage.googleapis.com].freeze
        INTERACTIONS_PATH_PATTERN = %r{/interactions(?:/[^/]+)?\z}
        INTERACTION_RETRIEVE_PATH_PATTERN = %r{/interactions/[^/]+\z}
        CACHE_PATH_PATTERN = %r{/cachedContents\z}
        TRACKED_PATH_PATTERN = Regexp.union(
          %r{/models/[^/:]+:(?:generateContent|streamGenerateContent)\z}, INTERACTIONS_PATH_PATTERN, CACHE_PATH_PATTERN
        )
        STREAM_PATH_PATTERN = /:streamGenerateContent\z/
        MODEL_PATH_PATTERN = %r{/models/([^/:]+)}
        PENDING_STATUSES = %w[queued in_progress].freeze
        TRAFFIC_TYPE_MODES = {
          "ON_DEMAND" => nil,
          "TRAFFIC_TYPE_UNSPECIFIED" => nil,
          "ON_DEMAND_PRIORITY" => "priority",
          "ON_DEMAND_FLEX" => "flex"
        }.freeze

        class << self
          def match?(url)
            uri_matches?(url) do |uri|
              HOSTS.include?(uri.host.to_s.downcase) && uri.path.to_s.match?(TRACKED_PATH_PATTERN)
            end
          end

          def provider_names
            %w[gemini]
          end
        end

        def streaming_request?(request_url, request_parsed)
          path_matches?(request_url, STREAM_PATH_PATTERN) || super
        end

        def parse(request_url:, request_body:, response_status:, response_body:, response_headers: nil)
          return nil unless response_status == 200

          response = safe_json_parse(response_body)
          request = safe_json_parse(request_body)
          if path_matches?(request_url, INTERACTIONS_PATH_PATTERN)
            return interaction_response_event(response, request_url:, request:, response_headers:)
          end
          return cache_storage_event(response) if path_matches?(request_url, CACHE_PATH_PATTERN)

          content_event(response, request_url:, request:, response_headers:)
        end

        def parse_stream(response_status:,
                         request_url: nil,
                         request_body: nil,
                         events: [],
                         response_headers: nil,
                         model: nil)
          return nil unless response_status == 200

          request = safe_json_parse(request_body)
          interaction = find_event_value(events, reverse: true) { |data| completed_interaction(data) }
          return interaction_event(interaction, request:, response_headers:, stream: true) if interaction

          content_stream_event(events, request:, request_url:, response_headers:, fallback_model: model)
        end

        def model_for(request_url, request_parsed)
          model_from_url(request_url) ||
            (request_parsed["model"] if path_matches?(request_url, INTERACTIONS_PATH_PATTERN))
        end

        def retain_stream_event?(data)
          data.is_a?(Hash) && Grounding.from_candidates(data["candidates"]).any?
        end

        def provider_for(_request_url)
          "gemini"
        end

        def service_line_items_for(response, model:)
          Grounding.from_response(response).line_items(model: model)
        end

        def cache_storage_event(response)
          tokens = response.dig("usageMetadata", "totalTokenCount")
          from = response["createTime"]
          to = response["expireTime"]
          return nil unless tokens && from && to

          Event.build(
            provider: "gemini",
            model: response["model"].to_s.split("/").last,
            token_usage: Usage::TokenUsage.build(input_tokens: 0, output_tokens: 0, total_tokens: 0),
            usage_source: Usage::Source::RESPONSE,
            provider_response_id: response["name"],
            service_line_items: [cache_storage_line_item(tokens, from, to)]
          )
        end

        def pricing_mode(request:, usage:, response_headers:, host: nil, model: nil)
          regional = Openai::Hosts.vertex_non_global?(host) &&
                     Pricing::Matcher.modifier_priced?(provider: "gemini", model: model, modifier: "data_residency")
          Pricing::Mode.compose([service_tier(request, usage, response_headers), ("data_residency" if regional)])
        end

        private

        def interaction_response_event(response, request_url:, request:, response_headers:)
          event = interaction_event(response, request:, response_headers:)
          return event unless event && path_matches?(request_url, INTERACTION_RETRIEVE_PATH_PATTERN)

          event unless Call.already_recorded?(provider: "gemini", provider_response_id: event.provider_response_id)
        end

        def interaction_event(interaction, request:, response_headers:, stream: false)
          usage = interaction["usage"]
          return nil unless usage.is_a?(Hash) && !PENDING_STATUSES.include?(interaction["status"])

          model = interaction["model"] || request["model"]
          metadata = UsageExtractor.from_interaction(usage, interaction["service_tier"])
          build_event(
            model: model,
            usage: metadata,
            stream: stream,
            usage_source: stream ? Usage::Source::STREAM_FINAL : Usage::Source::RESPONSE,
            provider_response_id: interaction["id"],
            pricing_mode: pricing_mode(request: request, usage: metadata, response_headers: response_headers),
            service_line_items: service_line_items_for(interaction, model: model)
          ).keyed_by_response_id
        end

        def content_event(response, request_url:, request:, response_headers:)
          usage = response["usageMetadata"]
          return nil unless usage

          model = response["modelVersion"].presence || model_from_url(request_url)
          host = parsed_uri(request_url)&.host
          build_event(
            model: model,
            usage: usage,
            usage_source: Usage::Source::RESPONSE,
            provider_response_id: response["responseId"],
            pricing_mode: pricing_mode(request:, usage:, response_headers:, host:, model:),
            service_line_items: service_line_items_for(response, model: model)
          )
        end

        def content_stream_event(events, request:, request_url:, response_headers:, fallback_model:)
          usage = last_usage_metadata(events)
          model = find_event_value(events, reverse: true) { |data| data["modelVersion"] } ||
                  model_from_url(request_url) || fallback_model || request["model"]
          host = parsed_uri(request_url)&.host
          attributes = {
            model: model,
            provider_response_id: find_event_value(events) { |data| data["responseId"] },
            pricing_mode: pricing_mode(request:, usage:, response_headers:, host:, model:),
            service_line_items: stream_grounding_line_items(events, model: model)
          }
          return build_unknown_stream_usage(provider: "gemini", **attributes) unless usage

          build_event(usage: usage, stream: true, usage_source: Usage::Source::STREAM_FINAL, **attributes)
        end

        def build_event(usage:, service_line_items:, **attributes)
          Event.build(
            provider: "gemini",
            token_usage: UsageExtractor.token_usage(usage),
            service_line_items: service_line_items + UsageExtractor.line_items(usage),
            **attributes
          )
        end

        def cache_storage_line_item(tokens, from, to)
          seconds = Time.iso8601(to) - Time.iso8601(from)
          Charges::LineItem.build(
            dimension_key: "cache_storage_token_hour",
            quantity: BigDecimal(tokens.to_s) * BigDecimal(seconds.to_s) / 3600,
            cost_status: Charges::CostStatus::UNKNOWN,
            pricing_basis: "provider_usage",
            provider_field: "response.usageMetadata.totalTokenCount",
            details: { cached_tokens: tokens, expire_time: to }
          )
        end

        def service_tier(request, usage, response_headers)
          reported_service_tier(usage) ||
            Pricing::Mode.normalize(response_header(response_headers, "x-gemini-service-tier")) ||
            requested_flex_tier(request)
        end

        def reported_service_tier(usage)
          return nil unless usage

          traffic = usage["trafficType"]
          Pricing::Mode.normalize(usage["serviceTier"]) ||
            TRAFFIC_TYPE_MODES.fetch(traffic.to_s) { Pricing::Mode.normalize(traffic) }
        end

        def requested_flex_tier(request)
          "flex" if Pricing::Mode.normalize(request["service_tier"] || request["serviceTier"]) == "flex"
        end

        def response_header(headers, name)
          headers.to_h.find { |key, _value| key.to_s.downcase == name }&.last
        end

        def path_matches?(url, pattern)
          uri_matches?(url) { |uri| uri.path.to_s.match?(pattern) }
        end

        def model_from_url(url)
          uri = parsed_uri(url)
          uri.path[MODEL_PATH_PATTERN, 1] if uri
        end

        def last_usage_metadata(events)
          find_event_value(events, reverse: true) do |data|
            metadata = data["usageMetadata"]
            metadata if metadata.is_a?(Hash)
          end
        end

        def completed_interaction(data)
          interaction = data["interaction"]
          interaction if interaction.is_a?(Hash) && interaction["usage"].is_a?(Hash)
        end

        def stream_grounding_line_items(events, model:)
          grounding = find_event_value(events, reverse: true) do |data|
            candidates = Grounding.from_candidates(data["candidates"])
            candidates if candidates.any?
          end
          grounding ? grounding.line_items(model: model) : []
        end
      end
    end
  end
end
