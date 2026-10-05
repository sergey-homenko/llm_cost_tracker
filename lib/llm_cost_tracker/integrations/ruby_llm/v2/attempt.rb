# frozen_string_literal: true

require "json"

module LlmCostTracker
  module Integrations
    module RubyLlm
      module V2
        module Attempt
          REFUSED = { input_tokens: 0, output_tokens: 0 }.freeze

          class << self
            def event(usage, payload, final:, events: nil, response: nil, raw: nil, provider: nil)
              base = Faraday::Response.new(url: URI(provider.api_base.to_s)) if provider
              return transcript_event(usage, payload, response, final, base) if response.is_a?(Hash)

              result = payload[:response] || payload[:result]
              shared = faraday_response(response, result.try(:raw))
              own = faraday_response(raw) || (shared if final)
              raw = own || shared || base
              converse_event(usage, payload, own, events) || stream_event(usage, events, raw) ||
                parsed_event(usage, own) || normalized_event(usage, payload, (result if final), raw)
            end

            def stream_window = Capture::EventWindow.new(notable: method(:notable_event?))

            def batch_event(usage, result, base)
              base = nil unless URI(base.to_s).host.to_s.match?(/\A(?:us|eu)\./i)
              raw = Faraday::Response.new(status: 200, response_body: result.try(:raw), url: URI(base.to_s))
              parsed = event(usage, { response: result }, final: true, raw: raw)
              return unless parsed

              source = parsed.usage_source == Usage::Source::UNKNOWN ? parsed.usage_source : Usage::Source::SDK_BATCH_RESULT
              parsed.with(pricing_mode: Pricing::Mode.merge("batch", parsed.pricing_mode), usage_source: source)
            end

            private

            def stream_parsers
              @stream_parsers ||= [Providers::Anthropic::Parser.new, Providers::Gemini::Parser.new,
                                   Providers::Openai::Parser.new]
            end

            def notable_event?(data) = stream_parsers.any? { |parser| parser.retain_stream_event?(data) }

            def faraday_response(*candidates) = candidates.find { |candidate| candidate.is_a?(Faraday::Response) }

            def raw_context(raw)
              { request_url: raw.env.url.to_s, request_body: raw.env.request_body, response_headers: raw.headers }
            end

            def stream_event(usage, events, raw)
              return unless events

              context = raw_context(raw).merge(response_status: 200, events: events)
              stream_parsers.lazy.filter_map { |parser| parser.parse_stream(**context) }
                            .find { |parsed| parsed.usage_source != Usage::Source::UNKNOWN }
                            &.with(provider: usage[:provider], usage_source: Usage::Source::SDK_RESPONSE)
            end

            def parsed_event(usage, raw)
              body = raw&.body
              return unless body.is_a?(Hash)

              response = raw_context(raw).merge(response_status: raw.status, response_body: body)
              event =
                if body["type"] == "message" then Providers::Anthropic::Parser.new.parse(**response)
                elsif body.key?("usageMetadata") || body["object"] == "interaction" then gemini_event(response)
                elsif openai_usage?(body["usage"]) then openai_event(usage, body, request_params(raw), raw.env.url.host)
                end
              event&.with(provider: usage[:provider], usage_source: Usage::Source::SDK_RESPONSE)
            end

            def transcript_event(usage, payload, body, final, base)
              if final && openai_usage?(body["usage"])
                request = payload[:provider_options].to_h.with_indifferent_access
                event = openai_event(usage, body, request, host(usage[:provider], base))
              end
              (event || normalized_event(usage, payload, (payload[:result] if final), base))&.with(stream: true)
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

            def gemini_event(response)
              event = Providers::Gemini::Parser.new.parse(**response)
              body = response[:response_body]
              details = body.dig("usageMetadata", body.key?("embedding") ? "promptTokensDetails" : "promptTokenDetails")
              video = Providers::Gemini::UsageExtractor.modality_tokens(details, "VIDEO")
              return event unless event && video.positive?

              event.with(line_items: [*event.line_items,
                                      Charges::LineItem.build(dimension_key: "video_input", quantity: video)])
            end

            def converse_event(usage, payload, raw, events)
              usages = [raw.try(:body), *events&.map { |event| event[:data] }].grep(Hash).map { |data| data["usage"] }
              counts = usages.reverse.find { |found| found.try(:key?, "inputTokens") }
              return unless counts

              ttl = payload[:caching].try(:[], :ttl)
              five_minute, one_hour = cache_writes(counts["cacheWriteInputTokens"].to_i, counts["cacheDetails"], ttl)
              Event.build(
                provider: usage[:provider],
                model: usage[:model],
                token_usage: Usage::TokenUsage.build(
                  input_tokens: counts["inputTokens"],
                  output_tokens: counts["outputTokens"],
                  cache_read_input_tokens: counts["cacheReadInputTokens"],
                  cache_write_input_tokens: five_minute,
                  cache_write_extended_input_tokens: one_hour,
                  hidden_output_tokens: usage[:tokens].thinking
                ),
                pricing_mode: pricing_mode(usage[:provider], usage[:model], {}, nil),
                stream: payload[:streaming],
                usage_source: Usage::Source::SDK_RESPONSE
              )
            end

            def normalized_event(usage, payload, result, raw)
              tokens = usage[:tokens]
              return if usage[:status] != :succeeded && tokens.to_h == REFUSED

              provider = usage[:provider]
              model = payload[:response_model] || usage[:model]
              request = request_params(raw).presence || payload[:provider_options].to_h.with_indifferent_access
              known = tokens.to_h.any? || !tokens.reported_cost.nil?
              line_items = if known
                             service_line_items(model, tokens, result, request)
                           else
                             result_line_items(usage[:operation], payload[:input], model, result)
                           end
              source = usage_source(usage, known || line_items.any?, result)
              return unless source

              Event.build(
                provider: provider,
                model: model,
                token_usage: token_usage(usage, model, payload[:caching]),
                pricing_mode: pricing_mode(provider, model, request, raw),
                stream: payload[:streaming],
                usage_source: source,
                provider_response_id: result.try(:id),
                service_line_items: line_items
              )
            end

            def usage_source(usage, known, result)
              return Usage::Source::SDK_RESPONSE if known
              return Usage::Source::UNKNOWN unless usage[:status] == :succeeded
              return if result.nil? || usage[:operation] == :chat

              usage[:operation] == :moderation ? Usage::Source::SDK_RESPONSE : Usage::Source::UNKNOWN
            end

            def token_usage(usage, model, caching)
              tokens = usage[:tokens]
              input = tokens.input.to_i
              output = tokens.output.to_i
              audio = usage[:operation] == :transcription && audio_priced?(usage[:provider], model) ? input : 0
              image = usage[:operation] == :image ? output : 0
              five_minute, one_hour = cache_writes(tokens.cache_write.to_i, nil, caching.try(:[], :ttl))
              Usage::TokenUsage.build(
                input_tokens: input - audio,
                audio_input_tokens: audio,
                output_tokens: output - image,
                image_output_tokens: image,
                cache_read_input_tokens: tokens.cache_read.to_i,
                cache_write_input_tokens: five_minute,
                cache_write_extended_input_tokens: one_hour,
                hidden_output_tokens: tokens.thinking.to_i
              )
            end

            def audio_priced?(provider, model)
              LlmCostTracker::Pricing::Matcher.lookup(provider: provider, model: model)&.prices&.key?("audio_input")
            end

            def cache_writes(total, details, ttl)
              one_hour = if details.is_a?(Array)
                           details.grep(Hash).sum { |detail| detail["ttl"] == "1h" ? detail["inputTokens"].to_i : 0 }
                         else
                           ttl.to_s == "1h" ? total : 0
                         end
              [[total - one_hour, 0].max, one_hour]
            end

            def service_line_items(model, tokens, result, request)
              if tokens.reported_cost
                return Providers::Openai::ServiceCharges.billed_line_items(cost: tokens.reported_cost)
              end

              calls = Array(result.try(:server_tool_calls)).map(&:raw).grep(Hash)
              grounding = { "candidates" => calls.map { |call| { "groundingMetadata" => call } } }
              server_tool_use = tokens.server_tool_use&.symbolize_keys
              Providers::Anthropic::UsageExtractor.service_line_items(server_tool_use: server_tool_use) +
                Providers::Openai::ServiceCharges.line_items_from_output(calls, request: request, model: model) +
                Providers::Gemini::Parser.new.service_line_items_for(grounding, model: model)
            end

            def result_line_items(operation, input, model, result)
              return [] unless result

              case operation
              when :speech then Providers::Openai::ServiceCharges.speech_line_items("input" => input, "model" => model)
              when :transcription
                seconds = result.try(:duration)
                return [] unless seconds

                Providers::Openai::ServiceCharges.transcription_line_items(type: "duration", seconds: seconds.to_f.ceil)
              else []
              end
            end

            def pricing_mode(provider, model, request, raw)
              case provider
              when "anthropic", "bedrock"
                Providers::Anthropic::UsageExtractor.pricing_mode(request: request.merge(model: model), usage: nil)
              when "gemini"
                Providers::Gemini::Parser.new.pricing_mode(request: request, usage: nil, response_headers: raw&.headers)
              else
                Providers::Openai::ResponseParser.combined_pricing_mode(
                  provider: provider, host: host(provider, raw), model: model, service_tier: request[:service_tier]
                )
              end
            end

            def host(provider, raw)
              base = raw ? raw.env.url : RubyLLM.config.try("#{provider}_api_base")
              URI(base.to_s).host if base
            end

            def request_params(raw)
              body = raw&.env&.request_body
              params = body.is_a?(String) ? JSON.parse(body) : body
              (params.is_a?(Hash) ? params : {}).with_indifferent_access
            rescue JSON::ParserError
              {}.with_indifferent_access
            end
          end
        end
      end
    end
  end
end
