# frozen_string_literal: true

module LlmCostTracker
  module Integrations
    module RubyLlm
      module V2
        class Attempt
          class TokenCounts
            REFUSED = { input_tokens: 0, output_tokens: 0 }.freeze

            def initialize(usage, payload, raw:, request:)
              @usage = usage
              @tokens = usage[:tokens]
              @payload = payload
              @raw = raw
              @request = request
            end

            def event(result:, response_id: nil)
              return if @usage[:status] != :succeeded && @tokens.to_h == REFUSED

              model = @payload[:response_model] || @usage[:model]
              line_items = line_items(model, result)
              source = usage_source(known? || line_items.any?, result)
              return unless source

              Event.build(
                provider: @usage[:provider],
                model: model,
                token_usage: token_usage(model),
                pricing_mode: pricing_mode(model),
                stream: @payload[:streaming],
                usage_source: source,
                provider_response_id: result.try(:id) || response_id,
                service_line_items: line_items
              )
            end

            def converse_event(counts)
              five_minute, one_hour = cache_writes(counts["cacheWriteInputTokens"].to_i, counts["cacheDetails"])
              Event.build(
                provider: @usage[:provider],
                model: @usage[:model],
                token_usage: Usage::TokenUsage.build(
                  input_tokens: counts["inputTokens"],
                  output_tokens: counts["outputTokens"],
                  cache_read_input_tokens: counts["cacheReadInputTokens"],
                  cache_write_input_tokens: five_minute,
                  cache_write_extended_input_tokens: one_hour,
                  hidden_output_tokens: @tokens.thinking
                ),
                pricing_mode: pricing_mode(@usage[:model]),
                stream: @payload[:streaming],
                usage_source: Usage::Source::SDK_RESPONSE
              )
            end

            def host
              base = @raw ? @raw.env.url : RubyLLM.config.try("#{@usage[:provider]}_api_base")
              URI(base.to_s).host if base
            end

            private

            def known? = @tokens.to_h.any? || !@tokens.reported_cost.nil?

            def usage_source(known, result)
              return Usage::Source::SDK_RESPONSE if known
              return Usage::Source::UNKNOWN unless @usage[:status] == :succeeded
              return if result.nil? || @usage[:operation] == :chat

              @usage[:operation] == :moderation ? Usage::Source::SDK_RESPONSE : Usage::Source::UNKNOWN
            end

            def token_usage(model)
              input = @tokens.input.to_i
              output = @tokens.output.to_i
              audio = @usage[:operation] == :transcription && audio_priced?(model) ? input : 0
              image = @usage[:operation] == :image ? output : 0
              five_minute, one_hour = cache_writes(@tokens.cache_write.to_i, nil)
              Usage::TokenUsage.build(
                input_tokens: input - audio,
                audio_input_tokens: audio,
                image_input_tokens: @usage[:image_tokens],
                output_tokens: output - image,
                image_output_tokens: image,
                cache_read_input_tokens: @tokens.cache_read.to_i,
                cache_write_input_tokens: five_minute,
                cache_write_extended_input_tokens: one_hour,
                hidden_output_tokens: @tokens.thinking.to_i
              )
            end

            def audio_priced?(model)
              Pricing::Matcher.lookup(provider: @usage[:provider], model: model)&.prices&.key?("audio_input")
            end

            def cache_writes(total, details)
              one_hour = if details.is_a?(Array)
                           details.grep(Hash).sum { |detail| detail["ttl"] == "1h" ? detail["inputTokens"].to_i : 0 }
                         else
                           @payload[:caching].try(:[], :ttl).to_s == "1h" ? total : 0
                         end
              [[total - one_hour, 0].max, one_hour]
            end

            def line_items(model, result)
              return result_line_items(model, result) unless known? && @usage[:operation] != :speech

              service_line_items(model, result)
            end

            def service_line_items(model, result)
              cost = @tokens.reported_cost
              return Providers::Openai::ServiceCharges.billed_line_items(cost: cost) if cost

              calls = Array(result.try(:server_tool_calls)).map(&:raw).grep(Hash)
              grounding = { "candidates" => calls.map { |call| { "groundingMetadata" => call } } }
              server_tool_use = @tokens.server_tool_use&.symbolize_keys
              Providers::Anthropic::UsageExtractor.service_line_items(server_tool_use: server_tool_use) +
                Providers::Openai::ServiceCharges.line_items_from_output(calls, request: @request, model: model) +
                Providers::Gemini::Parser.new.service_line_items_for(grounding, model: model)
            end

            def result_line_items(model, result)
              return [] unless result

              charges = Providers::Openai::ServiceCharges
              case @usage[:operation]
              when :speech then charges.speech_line_items("input" => @payload[:input], "model" => model)
              when :transcription
                seconds = result.try(:duration)
                seconds ? charges.transcription_line_items(type: "duration", seconds: seconds.to_f.ceil) : []
              when :ocr then charges.ocr_line_items(result.try(:raw).to_h)
              when :rerank then charges.rerank_line_items(result.try(:raw).to_h)
              else []
              end
            end

            def pricing_mode(model)
              case @usage[:provider]
              when "anthropic", "bedrock"
                Providers::Anthropic::UsageExtractor.pricing_mode(request: @request.merge(model: model), usage: nil)
              when "gemini"
                Providers::Gemini::Parser.new.pricing_mode(
                  request: @request, usage: nil, response_headers: @raw&.headers
                )
              else
                Providers::Openai::ResponseParser.combined_pricing_mode(
                  provider: @usage[:provider], host: host, model: model, service_tier: @request[:service_tier]
                )
              end
            end
          end
        end
      end
    end
  end
end
