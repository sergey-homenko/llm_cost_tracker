# frozen_string_literal: true

require "active_support/core_ext/hash/keys"

require_relative "hosts"
require_relative "model_families"
require_relative "service_charges"
require_relative "usage_extractor"

module LlmCostTracker
  module Providers
    module Openai
      module ResponseParser
        PENDING_STATUSES = %w[queued in_progress].freeze
        RETRIEVE_PATH_PATTERN = %r{/(?:responses|agent)/resp_}
        TRANSCRIPTION_PATH_PATTERN = %r{/audio/(?:transcriptions|translations)\z}

        class << self
          def combined_pricing_mode(host:, model:, service_tier:, provider: "openai")
            modes = [Pricing::Mode.normalize(service_tier)]
            owners = %w[gemini/ anthropic/] if Hosts.vertex_non_global?(host)
            if (owners || Hosts.data_residency?(host)) &&
               Pricing::Matcher.modifier_priced?(provider:, model:, modifier: "data_residency", owners:)
              modes << "data_residency"
            end
            Pricing::Mode.compose(modes)
          end

          def event_from_response(response:, request:, provider:, host:, usage_source:, pricing_mode: nil)
            usage = response["usage"]&.deep_symbolize_keys
            return nil if usage.nil? || pending?(response)

            model = response["model"] || request["model"]
            service_tier = response["service_tier"] || usage[:service_tier] || request["service_tier"]
            usage_event(
              usage,
              provider: provider,
              provider_response_id: response["id"],
              model: model,
              usage_source: usage_source,
              service_line_items: ServiceCharges.service_line_items_for(response, request: request, model: model),
              pricing_mode: pricing_mode || combined_pricing_mode(provider:, host:, model:, service_tier:)
            )
          end

          def retrieved_event(response:, provider:, host:, usage_source:)
            return nil unless response["background"] && response["usage"] && !pending?(response)
            return nil if Call.already_recorded?(provider: provider, provider_response_id: response["id"])

            event_from_response(
              response: response,
              request: { "tools" => response["tools"] },
              provider: provider,
              host: host,
              usage_source: usage_source
            )&.keyed_by_response_id
          end

          def usage_event(usage, model:, service_line_items:, **attributes)
            Event.build(
              model: model,
              token_usage: UsageExtractor.token_usage(usage, model: model),
              service_line_items: service_line_items + ServiceCharges.transcription_line_items(usage) +
                                  ServiceCharges.billed_line_items(usage) + UsageExtractor.cache_read_line_items(usage),
              **attributes
            )
          end

          private

          def pending?(response)
            PENDING_STATUSES.include?(response["status"].to_s)
          end
        end

        def parse(request_url:, request_body:, response_status:, response_body:, **)
          return nil unless response_status == 200

          response = safe_json_parse(response_body)
          uri = parsed_uri(request_url)
          source = { provider: provider_for(request_url), host: uri&.host, usage_source: Usage::Source::RESPONSE }
          if uri&.path.to_s.match?(RETRIEVE_PATH_PATTERN)
            return ResponseParser.retrieved_event(response: response, **source)
          end

          request = safe_json_parse(request_body)
          ResponseParser.event_from_response(response: response, request: request, **source) ||
            usage_free_event(request_url, request, response)
        end

        private

        def usage_free_event(request_url, request, response)
          path = parsed_uri(request_url)&.path.to_s
          if path.end_with?("/audio/speech")
            speech_event(request_url, request)
          elsif path.match?(TRANSCRIPTION_PATH_PATTERN)
            transcription_event(request_url, request, response)
          else
            ocr_event(request_url, request, response) ||
              (moderation_event(request_url, request, response) if path.end_with?("/moderations"))
          end
        end

        def speech_event(request_url, request)
          line_item_event(request_url, model_for(request_url, request), ServiceCharges.speech_line_items(request))
        end

        def transcription_event(request_url, request, response)
          seconds = response["duration"].to_f.ceil
          line_items = ServiceCharges.transcription_line_items(type: "duration", seconds: seconds)
          line_item_event(request_url, model_for(request_url, request) || Event::UNKNOWN_MODEL, line_items)
        end

        def line_item_event(request_url, model, line_items)
          zero_token_event(
            request_url,
            model: model,
            usage_source: line_items.empty? ? Usage::Source::UNKNOWN : Usage::Source::RESPONSE,
            service_line_items: line_items
          )
        end

        def ocr_event(request_url, request, response)
          line_items = ServiceCharges.ocr_line_items(response)
          return nil if line_items.empty?

          model = response["model"] || model_for(request_url, request)
          zero_token_event(
            request_url,
            model: model,
            pricing_mode: ResponseParser.combined_pricing_mode(
              provider: provider_for(request_url), host: parsed_uri(request_url)&.host, model: model, service_tier: nil
            ),
            usage_source: Usage::Source::RESPONSE,
            service_line_items: line_items
          )
        end

        def moderation_event(request_url, request, response)
          zero_token_event(
            request_url,
            model: response["model"] || model_for(request_url, request),
            provider_response_id: response["id"],
            usage_source: Usage::Source::RESPONSE
          )
        end

        def zero_token_event(request_url, **attributes)
          Event.build(
            provider: provider_for(request_url),
            token_usage: Usage::TokenUsage.build(input_tokens: 0, output_tokens: 0),
            **attributes
          )
        end
      end
    end
  end
end
