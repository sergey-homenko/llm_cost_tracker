# frozen_string_literal: true

require "json"
require "active_support/notifications"
require_relative "../base"

module LlmCostTracker
  module Integrations
    module RubyLlm
      module V2
        extend Base

        minimum_version "2.0.0"
        maximum_version "3.0.0"

        OPERATIONS = %w[chat compaction embedding image transcription moderation speech ocr rerank].freeze
        EVENTS = [*OPERATIONS, "request", "usage"].map { |name| "#{name}.ruby_llm" }.freeze
        FRAMES = :llm_cost_tracker_ruby_llm_frames
        REFUSED = { input_tokens: 0, output_tokens: 0 }.freeze
        Frame = Struct.new(:payload, :attempts, :request_started_at, :latency_ms)

        class << self
          def integration_name = :ruby_llm

          def install
            validate_contract!
            Logging.warn(untested_version_message) if untested_version?
            @subscriptions ||= EVENTS.map { |name| ActiveSupport::Notifications.subscribe(name, self) }
            RubyLLM.config.instrumenter ||= ActiveSupport::Notifications
          end

          def status
            name = integration_name.to_s
            problems = version_problems + target_problems
            if problems.any?
              return Check.new(:warn, name, "#{name} integration cannot be installed: #{problems.join('; ')}")
            end
            return Check.new(:warn, name, untested_version_message) if untested_version?
            return Check.new(:warn, name, "#{name} integration is enabled but not installed") unless @subscriptions

            instrumenter = RubyLLM.config.instrumenter
            return Check.new(:ok, name, "#{name} integration installed") if instrumenter == ActiveSupport::Notifications

            message = "RubyLLM.config.instrumenter is #{instrumenter.inspect}, not ActiveSupport::Notifications, " \
                      "so RubyLLM calls are not recorded"
            Check.new(:warn, name, message)
          end

          def start(name, _id, payload)
            case name
            when "usage.ruby_llm" then nil
            when "request.ruby_llm" then start_request
            else start_operation(payload)
            end
          end

          def finish(name, _id, payload)
            case name
            when "usage.ruby_llm" then add_attempt(payload)
            when "request.ruby_llm" then finish_request
            else finish_operation(payload)
            end
          end

          private

          def target_problems = defined?(RubyLLM.config) ? [] : ["RubyLLM is not loaded"]

          def frames = Thread.current[FRAMES] ||= []

          def start_operation(payload)
            return unless active?

            enforce_budget!(request: budget_request(payload), provider: payload[:provider].to_s)
            frames << Frame.new(payload, [])
          end

          def finish_operation(payload)
            index = frames.rindex { |frame| frame.payload.equal?(payload) }
            return unless index

            errors = frames.slice!(index..).flat_map { |frame| flush(frame) }
            raise errors.first if errors.any? && !payload[:exception]
          end

          def start_request
            frame = frames.last
            frame&.request_started_at = Timing.now_monotonic
            frame&.latency_ms = nil
          end

          def finish_request
            frame = frames.last
            frame.latency_ms = Timing.elapsed_ms(frame.request_started_at) if frame&.request_started_at
          end

          def add_attempt(usage)
            frame = frames.last
            return frame.attempts << [usage, frame.latency_ms] if frame
            return unless active?

            record_safely { record_attempt(usage, {}, nil, final: false) }
          end

          def flush(frame)
            final = frame.attempts.rindex { |usage, _| usage[:status] == :succeeded }
            frame.attempts.each_with_index.filter_map do |(usage, latency_ms), index|
              record_safely { record_attempt(usage, frame.payload, latency_ms, final: index == final) }
              nil
            rescue *CALLER_ERRORS => e
              e
            end
          end

          def record_attempt(usage, payload, latency_ms, final:)
            result = payload[:response] || payload[:result] if final
            raw = result.try(:raw)
            raw = nil unless raw.is_a?(Faraday::Response)
            event = parsed_event(usage[:provider], raw) || normalized_event(usage, payload, result, raw)
            return unless event

            workflow = { workflow: usage[:workflow_name], workflow_step: usage[:workflow_step_name] }.compact
            LlmCostTracker::Tracker.record(event: event, latency_ms: latency_ms, metadata: workflow)
          end

          def parsed_event(provider, raw)
            body = raw&.body
            return unless body.is_a?(Hash)

            response = { request_url: raw.env.url.to_s, request_body: raw.env.request_body,
                         response_status: raw.status, response_body: body, response_headers: raw.headers }
            event =
              if body["type"] == "message" then Providers::Anthropic::Parser.new.parse(**response)
              elsif body.key?("usageMetadata") || body["object"] == "interaction"
                Providers::Gemini::Parser.new.parse(**response)
              elsif %w[response chat.completion].include?(body["object"])
                Providers::Openai::ResponseParser.event_from_response(
                  response: body,
                  request: request_params(raw),
                  provider: provider,
                  host: raw.env.url.host,
                  usage_source: Usage::Source::SDK_RESPONSE
                )
              end
            event&.with(provider: provider, usage_source: Usage::Source::SDK_RESPONSE)
          end

          def normalized_event(usage, payload, result, raw)
            tokens = usage[:tokens]
            return if usage[:status] != :succeeded && tokens.to_h == REFUSED

            provider = usage[:provider]
            model = payload[:response_model] || usage[:model]
            request = request_params(raw)
            known = tokens.to_h.any? || !tokens.reported_cost.nil?
            line_items = if known
                           service_line_items(model, tokens, result, request)
                         else
                           duration_line_items(usage, result)
                         end
            source = usage_source(usage, known || line_items.any?, result)
            return unless source

            Event.build(
              provider: provider,
              model: model,
              token_usage: token_usage(usage, model, raw, payload[:caching]),
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

          def token_usage(usage, model, raw, caching)
            tokens = usage[:tokens]
            input = tokens.input.to_i
            output = tokens.output.to_i
            audio = usage[:operation] == :transcription && audio_priced?(usage[:provider], model) ? input : 0
            image = usage[:operation] == :image ? output : 0
            five_minute, one_hour = cache_writes(tokens.cache_write.to_i, raw, caching.try(:[], :ttl))
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

          def cache_writes(total, raw, ttl)
            details = raw.body.dig("usage", "cacheDetails") if raw&.body.is_a?(Hash)
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

          def duration_line_items(usage, result)
            seconds = result.try(:duration) if usage[:operation] == :transcription
            return [] unless seconds

            Providers::Openai::ServiceCharges.transcription_line_items(type: "duration", seconds: seconds.to_f.ceil)
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

          def budget_request(payload)
            messages = payload[:input_messages]
            input = if messages
                      messages.map { |message| message.try(:content).then { |content| content.try(:text) || content } }
                    else
                      payload.values_at(:input, :prompt, :query)
                    end
            { model: payload[:model], input: input }
          end
        end
      end
    end
  end
end
