# frozen_string_literal: true

module LlmCostTracker
  module Providers
    module Gemini
      class Parser < LlmCostTracker::Parsers::Base
        HOSTS = %w[generativelanguage.googleapis.com].freeze
        TRACKED_PATH_PATTERN = %r{/models/[^/:]+:(?:generateContent|streamGenerateContent)\z}
        STREAM_PATH_PATTERN  = /:streamGenerateContent\z/

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
          return true if uri_matches?(request_url) { |uri| uri.path.to_s.match?(STREAM_PATH_PATTERN) }

          super
        end

        def parse(request_url:, request_body:, response_status:, response_body:, response_headers: nil)
          return nil unless response_status == 200

          response = safe_json_parse(response_body)
          usage    = response["usageMetadata"]
          return nil unless usage

          request = safe_json_parse(request_body)
          model = extract_model_from_url(request_url)
          build_event(
            model: model,
            usage: usage,
            usage_source: Usage::Source::RESPONSE,
            provider_response_id: response["responseId"],
            pricing_mode: pricing_mode(request: request, usage: usage, response_headers: response_headers),
            service_line_items: service_line_items_for(response, model: model)
          )
        end

        def parse_stream(response_status:, request_url: nil, request_body: nil, events: [], response_headers: nil)
          return nil unless response_status == 200

          request = safe_json_parse(request_body)
          usage = merged_stream_usage(events)
          model = extract_model_from_url(request_url)
          response_id = find_event_value(events) { |data| data["responseId"] }
          mode = pricing_mode(request: request, usage: usage, response_headers: response_headers)
          service_line_items = grounding_line_items_for_stream(events, model: model)

          if usage
            build_event(
              model: model,
              usage: usage,
              stream: true,
              usage_source: Usage::Source::STREAM_FINAL,
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

        def model_for(request_url, _request_parsed)
          extract_model_from_url(request_url)
        end

        def retain_stream_event?(data)
          data.is_a?(Hash) && grounding_request_count(data["candidates"]).positive?
        end

        def provider_for(_request_url)
          "gemini"
        end

        def service_line_items_for(response, model:)
          grounding_line_items(grounding_request_count(response["candidates"]), model: model)
        end

        private

        def build_event(model:,
                        usage:,
                        usage_source:,
                        provider_response_id:,
                        pricing_mode:,
                        service_line_items:,
                        stream: false)
          Event.build(
            provider: "gemini",
            model: model,
            pricing_mode: pricing_mode,
            token_usage: UsageExtractor.token_usage(usage),
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

        def extract_model_from_url(url)
          uri = parsed_uri(url)
          return nil unless uri

          match = uri.path.match(%r{/models/([^/:]+)})
          match && match[1]
        end

        def pricing_mode(request:, usage:, response_headers:)
          body_mode = Pricing::Mode.normalize(usage && usage["serviceTier"])
          return body_mode if body_mode

          header_mode = Pricing::Mode.normalize(response_header(response_headers, "x-gemini-service-tier"))
          return header_mode if header_mode

          request_mode = Pricing::Mode.normalize(request["service_tier"] || request["serviceTier"])
          request_mode == "flex" ? request_mode : nil
        end

        def response_header(headers, name)
          headers.to_h.find { |key, _value| key.to_s.downcase == name }&.last
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
            queries = candidate.dig("groundingMetadata", "webSearchQueries") || []
            Array(queries).size
          end
        end

        def grounding_line_items(query_count, model:)
          return [] unless query_count.positive?

          [
            Charges::LineItem.build(
              dimension_key: "grounding_request",
              quantity: ModelFamilies.per_query_grounding?(model) ? query_count : 1,
              cost_status: Charges::CostStatus::UNKNOWN,
              pricing_basis: "provider_usage",
              provider_field: "response.candidates.groundingMetadata.webSearchQueries",
              details: { web_search_queries: query_count }
            )
          ]
        end
      end
    end
  end
end
