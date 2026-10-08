# frozen_string_literal: true

require "json"
require_relative "attempt/token_counts"

module LlmCostTracker
  module Integrations
    module RubyLlm
      module V2
        class Attempt
          attr_reader :usage, :latency_ms

          class << self
            def stream_window
              Capture::EventWindow.new(notable: method(:notable_event?),
                                       trim: stream_parsers.last.method(:trim_stream_event))
            end

            def batch_event(usage, result, base)
              base = nil unless URI(base.to_s).host.to_s.match?(/\A(?:us|eu)\.|aiplatform\./i)
              raw = Faraday::Response.new(status: 200, response_body: result.try(:raw), url: URI(base.to_s))
              parsed = new(usage, { response: result }, final: true, raw: raw).event
              return unless parsed

              source = parsed.usage_source == Usage::Source::UNKNOWN ? parsed.usage_source : Usage::Source::SDK_BATCH_RESULT
              parsed.with(pricing_mode: Pricing::Mode.merge("batch", parsed.pricing_mode), usage_source: source)
            end

            def request_params(raw, payload)
              body = raw&.env&.request_body
              params = body.is_a?(String) ? JSON.parse(body) : body
              ((params.presence if params.is_a?(Hash)) || payload[:provider_options].to_h).with_indifferent_access
            rescue JSON::ParserError
              payload[:provider_options].to_h.with_indifferent_access
            end

            def stream_parsers
              @stream_parsers ||= [Providers::Anthropic::Parser.new, Providers::Gemini::Parser.new,
                                   Providers::Openai::Parser.new]
            end

            private

            def notable_event?(data) = stream_parsers.any? { |parser| parser.retain_stream_event?(data) }
          end

          def initialize(usage, payload, final:, latency_ms: nil, events: nil, response: nil, raw: nil, provider: nil)
            @usage = usage
            @payload = payload
            @final = final
            @latency_ms = latency_ms
            @events = events
            @response = response
            @raw = raw
            @provider = provider
          end

          def event
            base = Faraday::Response.new(url: URI(@provider.api_base.to_s)) if @provider
            @response.is_a?(Hash) ? transcript_event(base) : response_event(base)
          end

          private

          def transcript_event(base)
            counts = TokenCounts.new(@usage, @payload, raw: base, request: Attempt.request_params(base, @payload))
            if @final && openai_usage?(@response["usage"])
              event = openai_event(@usage, @response, Attempt.request_params(base, @payload), counts.host)
            end
            (event || counts.event(result: (@payload[:result] if @final)))&.with(stream: true)
          end

          def response_event(base)
            own = faraday_response(@raw, *(shared_responses if @final))
            raw = faraday_response(@raw, *shared_responses) || base
            request = Attempt.request_params(raw, @payload)
            usage = billed_units(own)
            converse_event(usage, own) || stream_event(usage, raw, request) || parsed_event(usage, own, request) ||
              TokenCounts.new(usage, @payload, raw: raw, request: request)
                         .event(result: (result if @final), response_id: response_id(own))
          end

          def result = @payload[:response] || @payload[:result]

          def shared_responses = [@response, result.try(:raw)]

          def faraday_response(*candidates) = candidates.find { |candidate| candidate.is_a?(Faraday::Response) }

          def converse_event(usage, own)
            data = bodies(own).reverse.find { |body| body["usage"].try(:key?, "inputTokens") }
            return unless data

            request = { service_tier: data["serviceTier"].try(:[], "type") }
            TokenCounts.new(usage, @payload, raw: nil, request: request).converse_event(data["usage"])
          end

          def stream_event(usage, raw, request)
            return unless @events

            context = raw_context(raw, request).merge(response_status: 200, events: @events)
            Attempt.stream_parsers.lazy.filter_map { |parser| parser.parse_stream(**context) }
                   .find { |parsed| parsed.usage_source != Usage::Source::UNKNOWN }
                   &.with(provider: usage[:provider], usage_source: Usage::Source::SDK_RESPONSE)
          end

          def parsed_event(usage, own, request)
            body = own&.body
            return unless body.is_a?(Hash)

            response = raw_context(own, request).merge(response_status: own.status, response_body: body)
            event = body_event(usage, own, request, response)
            event&.with(provider: usage[:provider], usage_source: Usage::Source::SDK_RESPONSE)
          end

          def body_event(usage, own, request, response)
            body = response[:response_body]
            if body["type"] == "message" then Providers::Anthropic::Parser.new.parse(**response)
            elsif body.key?("usageMetadata") || body["object"] == "interaction" then gemini_event(response)
            elsif openai_usage?(body["usage"]) then openai_event(usage, body, request, own.env.url.host)
            end
          end

          def raw_context(raw, request)
            { request_url: raw.env.url.to_s, request_body: request, response_headers: raw.headers }
          end

          def gemini_event(response)
            event = Providers::Gemini::Parser.new.parse(**response)
            body = response[:response_body]
            details = body.dig("usageMetadata", body.key?("embedding") ? "promptTokensDetails" : "promptTokenDetails")
            video = Providers::Gemini::UsageExtractor.modality_tokens(details, "VIDEO")
            return event unless event && video.positive?

            event.with(line_items: [*event.line_items,
                                    Charges::LineItem.build(dimension_key: "video_input", quantity: video)])
          end

          def openai_event(usage, body, request, host)
            request[:model] ||= usage[:model]
            Providers::Openai::ResponseParser.event_from_response(
              response: body,
              request: request,
              provider: usage[:provider],
              host: host,
              usage_source: Usage::Source::SDK_RESPONSE
            )
          end

          def openai_usage?(usage)
            usage.is_a?(Hash) &&
              (usage.key?("input_tokens") || usage.key?("prompt_tokens") || usage.key?("cost_in_usd_ticks") ||
               usage["type"] == "duration")
          end

          def bodies(own) = [own&.body, *@events&.map { |event| event[:data] }].grep(Hash)

          def response_id(own) = bodies(own).filter_map { |body| body["id"] || body["responseId"] }.first

          def billed_units(own)
            units = bodies(own).filter_map do |data|
              (data["type"] == "message-end" ? data.dig("delta", "usage") : data["usage"] || data["meta"])
                .try(:[], "billed_units")
            end.last
            return @usage unless units

            tokens = @usage[:tokens]
            @usage.merge(tokens: RubyLLM::Tokens.new(input: units["input_tokens"] || tokens.input,
                                                     output: units["output_tokens"] || tokens.output),
                         image_tokens: units["image_tokens"])
          end
        end
      end
    end
  end
end
