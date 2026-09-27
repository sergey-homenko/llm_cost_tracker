# frozen_string_literal: true

require "bigdecimal"
require "time"

module LlmCostTracker
  module Providers
    module Gemini
      class Parser < LlmCostTracker::Parsers::Base
        HOSTS = %w[generativelanguage.googleapis.com].freeze
        INTERACTIONS_PATH_PATTERN = %r{/interactions(?:/[^/]+)?\z}
        CACHE_PATH_PATTERN = %r{/cachedContents\z}
        TRACKED_PATH_PATTERN = Regexp.union(
          %r{/models/[^/:]+:(?:generateContent|streamGenerateContent)\z}, INTERACTIONS_PATH_PATTERN, CACHE_PATH_PATTERN
        )
        STREAM_PATH_PATTERN = /:streamGenerateContent\z/
        GROUNDING_FIELDS = {
          "grounding_request" => "response.candidates.groundingMetadata.webSearchQueries",
          "maps_grounding_request" => "response.candidates.groundingMetadata.groundingChunks.maps"
        }.freeze
        INTERACTION_GROUNDING_KINDS = {
          "google_search" => "grounding_request",
          "google_maps" => "maps_grounding_request"
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
          return true if path_matches?(request_url, STREAM_PATH_PATTERN)

          super
        end

        def parse(request_url:, request_body:, response_status:, response_body:, response_headers: nil)
          return nil unless response_status == 200

          response = safe_json_parse(response_body)
          request = safe_json_parse(request_body)
          if path_matches?(request_url, INTERACTIONS_PATH_PATTERN)
            event = interaction_event(response, request: request, response_headers: response_headers)
            # A GET of a stored interaction records nothing, so it does not notify or raise over budget again.
            return nil if event && path_matches?(request_url, %r{/interactions/[^/]+\z}) &&
                          Call.already_recorded?(provider: "gemini", provider_response_id: event.provider_response_id)

            return event
          end
          return cache_storage_event(response) if path_matches?(request_url, CACHE_PATH_PATTERN)

          usage = response["usageMetadata"]
          return nil unless usage

          model = response["modelVersion"].presence || extract_model_from_url(request_url)
          build_event(
            model: model,
            usage: usage,
            usage_source: Usage::Source::RESPONSE,
            provider_response_id: response["responseId"],
            pricing_mode: pricing_mode(request: request, usage: usage, response_headers: response_headers),
            service_line_items: service_line_items_for(response, model: model)
          )
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
          if interaction
            return interaction_event(interaction, request: request, response_headers: response_headers, stream: true)
          end

          usage = merged_stream_usage(events)
          model = find_event_value(events, reverse: true) { |data| data["modelVersion"] } ||
                  extract_model_from_url(request_url) || model || request["model"]
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

        def model_for(request_url, request_parsed)
          extract_model_from_url(request_url) ||
            (request_parsed["model"] if path_matches?(request_url, INTERACTIONS_PATH_PATTERN))
        end

        def retain_stream_event?(data)
          data.is_a?(Hash) && grounding_counts(data["candidates"]).values.any?(&:positive?)
        end

        def provider_for(_request_url)
          "gemini"
        end

        def service_line_items_for(response, model:)
          usage = response["usage"]
          return grounding_line_items(grounding_counts(response["candidates"]), model: model) unless usage.is_a?(Hash)

          counts = Array(usage["grounding_tool_count"]).each_with_object(Hash.new(0)) do |entry, acc|
            kind = INTERACTION_GROUNDING_KINDS[entry["type"]]
            acc[kind] += entry["count"].to_i if kind
          end
          grounding_line_items(counts, model: model, provider_field: "response.usage.grounding_tool_count")
        end

        def interaction_usage_metadata(usage, service_tier)
          {
            "promptTokenCount" => usage["total_input_tokens"],
            "cachedContentTokenCount" => usage["total_cached_tokens"],
            "toolUsePromptTokenCount" => usage["total_tool_use_tokens"],
            "candidatesTokenCount" => usage["total_output_tokens"],
            "thoughtsTokenCount" => usage["total_thought_tokens"],
            "totalTokenCount" => usage["total_tokens"],
            "promptTokensDetails" => modality_details(usage["input_tokens_by_modality"]),
            "cacheTokensDetails" => modality_details(usage["cached_tokens_by_modality"]),
            "candidatesTokensDetails" => modality_details(usage["output_tokens_by_modality"]),
            "serviceTier" => service_tier
          }
        end

        def cache_storage_event(response)
          tokens = response.dig("usageMetadata", "totalTokenCount")
          from = response["createTime"]
          to = response["expireTime"]
          return nil unless tokens && from && to

          seconds = Time.iso8601(to) - Time.iso8601(from)
          Event.build(
            provider: "gemini",
            model: response["model"].to_s.delete_prefix("models/"),
            token_usage: Usage::TokenUsage.build(input_tokens: 0, output_tokens: 0, total_tokens: 0),
            usage_source: Usage::Source::RESPONSE,
            provider_response_id: response["name"],
            service_line_items: [
              Charges::LineItem.build(
                dimension_key: "cache_storage_token_hour",
                quantity: BigDecimal(tokens.to_s) * BigDecimal(seconds.to_s) / 3600,
                cost_status: Charges::CostStatus::UNKNOWN,
                pricing_basis: "provider_usage",
                provider_field: "response.usageMetadata.totalTokenCount",
                details: { cached_tokens: tokens, expire_time: to }
              )
            ]
          )
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
            service_line_items: service_line_items + UsageExtractor.cache_read_line_items(usage)
          )
        end

        def path_matches?(url, pattern)
          uri_matches?(url) { |uri| uri.path.to_s.match?(pattern) }
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

        def completed_interaction(data)
          interaction = data["interaction"]
          interaction if interaction.is_a?(Hash) && interaction["usage"].is_a?(Hash)
        end

        def interaction_event(interaction, request:, response_headers:, stream: false)
          usage = interaction["usage"]
          return nil unless usage.is_a?(Hash) && !%w[queued in_progress].include?(interaction["status"])

          model = interaction["model"] || request["model"]
          metadata = interaction_usage_metadata(usage, interaction["service_tier"])
          build_event(
            model: model,
            usage: metadata,
            stream: stream,
            usage_source: stream ? Usage::Source::STREAM_FINAL : Usage::Source::RESPONSE,
            provider_response_id: interaction["id"],
            pricing_mode: pricing_mode(request: request, usage: metadata, response_headers: response_headers),
            service_line_items: service_line_items_for(interaction, model: model)
          ).keyed_by_response_id # stored once, however often a GET fetches it again
        end

        def modality_details(entries)
          Array(entries).map do |entry|
            { "modality" => entry["modality"].to_s.upcase, "tokenCount" => entry["tokens"] }
          end
        end

        def grounding_line_items_for_stream(events, model:)
          counts = find_event_value(events, reverse: true) do |data|
            candidate_counts = grounding_counts(data["candidates"])
            candidate_counts if candidate_counts.values.any?(&:positive?)
          end
          grounding_line_items(counts || {}, model: model)
        end

        def grounding_counts(candidates)
          Array(candidates).each_with_object(Hash.new(0)) do |candidate, counts|
            meta = candidate["groundingMetadata"]
            next unless meta.is_a?(Hash)

            queries = unique_query_count(meta["webSearchQueries"])
            if Array(meta["groundingChunks"]).any? { |chunk| chunk.is_a?(Hash) && chunk.key?("maps") }
              counts["maps_grounding_request"] += [queries, 1].max
            else
              counts["grounding_request"] += queries + unique_query_count(meta["imageSearchQueries"])
            end
          end
        end

        def unique_query_count(queries)
          Array(queries).map { |query| query.to_s.strip }.reject(&:empty?).uniq.size
        end

        def grounding_line_items(counts, model:, provider_field: nil)
          counts.filter_map do |kind, count|
            next unless count.positive?

            Charges::LineItem.build(
              dimension_key: kind,
              quantity: ModelFamilies.per_query_grounding?(model) ? count : 1,
              cost_status: Charges::CostStatus::UNKNOWN,
              pricing_basis: "provider_usage",
              provider_field: provider_field || GROUNDING_FIELDS.fetch(kind),
              details: { web_search_queries: count }
            )
          end
        end
      end
    end
  end
end
