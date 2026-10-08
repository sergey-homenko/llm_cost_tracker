# frozen_string_literal: true

require_relative "base"
require_relative "../capture/sdk_payload"
require_relative "../charges/line_item"
require_relative "../providers/azure/hosts"
require_relative "../providers/openai/model_families"
require_relative "../providers/openai/service_charges"
require_relative "../providers/openai/usage_extractor"
require_relative "openai/patches"
require_relative "openai/batch_capture"
require_relative "openai/websocket_capture"

module LlmCostTracker
  module Integrations
    module Openai
      extend Base

      minimum_version "0.59.0"

      class << self
        def patch_targets
          [
            patch_target("OpenAI::Resources::Responses", with: ResponsesPatch),
            patch_target("OpenAI::Resources::Beta::Responses",
                         with: ResponsesPatch,
                         optional: true,
                         skip_when_methods_missing: true),
            patch_target("OpenAI::Responses::Connection", with: ResponsesConnectionPatch, optional: true),
            patch_target("OpenAI::Resources::Chat::Completions", with: ChatCompletionsPatch),
            patch_target("OpenAI::Resources::Completions", with: CreatePatch, optional: true),
            patch_target("OpenAI::Resources::Embeddings", with: CreatePatch, optional: true),
            patch_target("OpenAI::Resources::Images", with: ImagesPatch, optional: true),
            patch_target("OpenAI::Resources::Images",
                         with: StreamingImagesPatch,
                         optional: true,
                         skip_when_methods_missing: true),
            patch_target("OpenAI::Resources::Audio::Transcriptions", with: TranscriptionsPatch, optional: true),
            patch_target("OpenAI::Resources::Audio::Transcriptions",
                         with: StreamingTranscriptionsPatch,
                         optional: true,
                         skip_when_methods_missing: true),
            patch_target("OpenAI::Resources::Audio::Translations", with: TranslationsPatch, optional: true),
            patch_target("OpenAI::Resources::Audio::Speech", with: SpeechPatch, optional: true),
            patch_target("OpenAI::Resources::Moderations", with: ModerationsPatch, optional: true),
            patch_target("OpenAI::Resources::Batches", with: BatchesPatch, optional: true)
          ]
        end

        def provider_for_host(host)
          return "azure_openai" if Providers::Azure::Hosts.openai?(host)

          LlmCostTracker.configuration.capture.openai_compatible_providers[host.to_s.downcase] ||
            (Providers::Openai::Hosts.bedrock?(host) ? "bedrock" : "openai")
        end

        def blocking_seam(client, record_method)
          host = client_host(client)
          {
            provider: provider_for_host(host),
            record: lambda do |response, request, latency_ms|
              public_send(record_method, response, request: request, latency_ms: latency_ms, host: host)
            end
          }
        end

        def stream_seam(client)
          host = client_host(client)
          { provider: provider_for_host(host), collector: ->(request) { stream_collector(request, host: host) } }
        end

        def stream_collector(request, host: nil)
          Capture::StreamCollector.new(
            provider: provider_for_host(host),
            parsed_as: "openai",
            model: request[:model],
            pricing_mode: host_pricing_mode(host, request),
            request: request
          )
        end

        def record_response(response, request:, latency_ms:, host: nil)
          return unless active?

          record_safely do
            body = Capture::SdkPayload.normalize(response)
            next warn_missing_usage(body) unless tokens_reported?(body)

            event = Providers::Openai::ResponseParser.event_from_response(
              response: body,
              request: request,
              provider: provider_for_host(host),
              host: host,
              usage_source: Usage::Source::SDK_RESPONSE
            )
            Tracker.record(event: event, latency_ms: latency_ms) if event
          end
        end

        def record_retrieved_response(response, host:)
          return unless active?

          record_safely do
            event = Providers::Openai::ResponseParser.retrieved_event(
              response: Capture::SdkPayload.normalize(response),
              provider: provider_for_host(host),
              host: host,
              usage_source: Usage::Source::SDK_RESPONSE
            )
            record_once(event) if event
          end
        end

        def record_image(response, request:, latency_ms:, host: nil)
          usage = usage_hash_from(response) || {}
          extractor = Providers::Openai::UsageExtractor
          record_passthrough(
            model: request[:model],
            response: response,
            latency_ms: latency_ms,
            provider: provider_for_host(host),
            pricing_mode: host_pricing_mode(host, request),
            service_line_items: Providers::Openai::ServiceCharges.billed_line_items(usage) +
                                extractor.cache_read_line_items(usage),
            **extractor.token_usage(usage, model: request[:model], default_to_image: true).to_h
          )
        end

        def record_transcription(response, request:, latency_ms:, host: nil)
          usage = transcription_usage(response)
          record_passthrough(
            model: request[:model],
            response: response,
            latency_ms: latency_ms,
            provider: provider_for_host(host),
            pricing_mode: host_pricing_mode(host, request),
            service_line_items: Providers::Openai::ServiceCharges.transcription_line_items(usage),
            usage_source: usage ? Usage::Source::SDK_RESPONSE : Usage::Source::UNKNOWN,
            **transcription_token_attributes(usage)
          )
        end

        def record_speech(response, request:, latency_ms:, host: nil)
          if request[:stream_format].to_s == "sse" && response.respond_to?(:string)
            return record_speech_stream(response, request: request, latency_ms: latency_ms, host: host)
          end

          line_items = Providers::Openai::ServiceCharges.speech_line_items(request)
          record_passthrough(
            model: request[:model],
            response: nil,
            latency_ms: latency_ms,
            provider: provider_for_host(host),
            input_tokens: 0,
            output_tokens: 0,
            service_line_items: line_items,
            usage_source: line_items.empty? ? Usage::Source::UNKNOWN : Usage::Source::SDK_RESPONSE
          )
        end

        def record_moderation(response, request:, latency_ms:, host: nil)
          record_passthrough(
            model: response.model || request[:model],
            response: response,
            latency_ms: latency_ms,
            provider: provider_for_host(host),
            input_tokens: 0,
            output_tokens: 0
          )
        end

        private

        def host_pricing_mode(host, request)
          Providers::Openai::ResponseParser.combined_pricing_mode(
            provider: provider_for_host(host), host: host, model: request[:model], service_tier: nil
          )
        end

        def usage_hash_from(response)
          response.try(:usage)&.deep_to_h
        end

        def tokens_reported?(body)
          usage = body["usage"] || {}
          input_tokens = usage["input_tokens"] || usage["prompt_tokens"]
          output_tokens = usage["output_tokens"] || usage["completion_tokens"]
          !(input_tokens.nil? && output_tokens.nil?)
        end

        def warn_missing_usage(body)
          Logging.warn("OpenAI response #{body['id']} has no usage; not recorded") unless body["background"]
        end

        def transcription_usage(response)
          body = Hash.try_convert(Capture::SdkPayload.normalize(response)) || {}
          usage = body["usage"]&.deep_symbolize_keys
          usage ||= { type: "duration", seconds: body["duration"].ceil } if body["duration"].to_f.positive?
          usage
        end

        def transcription_token_attributes(usage)
          return { input_tokens: 0, output_tokens: 0 } unless usage && usage[:type].to_s == "tokens"

          raw_input = usage[:input_tokens].to_i
          audio_input = Providers::Openai::UsageExtractor.audio_input_tokens(usage)
          {
            input_tokens: [raw_input - audio_input, 0].max,
            audio_input_tokens: audio_input,
            output_tokens: usage[:output_tokens].to_i
          }
        end

        def record_speech_stream(response, request:, latency_ms:, host:)
          return unless active?

          collector = Capture::StreamCollector.new(
            provider: provider_for_host(host),
            model: request[:model],
            latency_ms: latency_ms,
            pricing_mode: host_pricing_mode(host, request),
            request: request
          )
          Capture::SSE.parse(response.string).each { |event| collector.event(event[:data]) }
          collector.finish!
        end
      end
    end
  end
end
