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

module LlmCostTracker
  module Integrations
    module Openai
      extend Base

      minimum_version "0.59.0"

      class << self
        def stream_pricing_mode(request, host: nil)
          LlmCostTracker::Providers::Openai::UsageParser.combined_pricing_mode(
            host: host,
            model: (request || {})[:model],
            service_tier: (request || {})[:service_tier]
          )
        end

        def stream_collector(request, host: nil)
          LlmCostTracker::Capture::StreamCollector.new(
            provider: provider_for_host(host),
            model: request[:model],
            pricing_mode: stream_pricing_mode(request, host: host),
            request: request
          )
        end

        def stream_seam(resource)
          host = client_host_for(resource)
          {
            provider: provider_for_host(host),
            collector: ->(request) { stream_collector(request, host: host) }
          }
        end

        def client_host_for(resource)
          client = resource.instance_variable_get(:@client)
          return nil unless client

          URI.parse(client.base_url.to_s).host
        rescue URI::InvalidURIError
          nil
        end

        def provider_for_host(host)
          LlmCostTracker::Providers::Azure::Hosts.openai?(host) ? "azure_openai" : "openai"
        end

        def patch_targets
          [
            patch_target("OpenAI::Resources::Responses", with: ResponsesPatch),
            patch_target("OpenAI::Resources::Chat::Completions", with: ChatCompletionsPatch),
            *auxiliary_patch_targets
          ]
        end

        def auxiliary_patch_targets
          [
            patch_target("OpenAI::Resources::Embeddings", with: EmbeddingsPatch, optional: true),
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

        def record_response(response, request:, latency_ms:, host: nil)
          return unless active?

          record_safely do
            normalized = LlmCostTracker::Capture::SdkPayload.normalize(response)
            usage = normalized["usage"]
            if usage
              input_tokens = usage["input_tokens"] || usage["prompt_tokens"]
              output_tokens = usage["output_tokens"] || usage["completion_tokens"]
              next if input_tokens.nil? && output_tokens.nil?
            end

            event = LlmCostTracker::Providers::Openai::UsageParser.event_from_response(
              response: normalized,
              request: request,
              provider: provider_for_host(host),
              host: host,
              usage_source: LlmCostTracker::Usage::Source::SDK_RESPONSE
            )
            LlmCostTracker::Tracker.record(event: event, latency_ms: latency_ms) if event
          end
        end

        def record_image(response, request:, latency_ms:, host: nil)
          usage = usage_hash_from(response) || {}
          raw_input = usage[:input_tokens].to_i
          image_input = LlmCostTracker::Providers::Openai::UsageExtractor.image_input_tokens(usage)
          cache_read = LlmCostTracker::Providers::Openai::UsageExtractor.cache_read_input_tokens(usage)
          image_output, text_output = LlmCostTracker::Providers::Openai::UsageExtractor.split_output(
            output_tokens: usage[:output_tokens].to_i,
            image_output_details: LlmCostTracker::Providers::Openai::UsageExtractor.image_output_tokens(usage),
            text_output_details: LlmCostTracker::Providers::Openai::UsageExtractor.text_output_tokens(usage),
            audio_output: 0,
            default_to_image: true
          )
          record_passthrough(
            model: request[:model],
            response: response,
            latency_ms: latency_ms,
            host: host,
            input_tokens: [raw_input - image_input - cache_read, 0].max,
            image_input_tokens: image_input,
            output_tokens: text_output,
            image_output_tokens: image_output,
            cache_read_input_tokens: cache_read
          )
        end

        def record_transcription(response, request:, latency_ms:, host: nil)
          usage = usage_hash_from(response)
          record_passthrough(
            model: request[:model],
            response: response,
            latency_ms: latency_ms,
            host: host,
            service_line_items: LlmCostTracker::Providers::Openai::ServiceCharges.transcription_line_items(usage),
            **transcription_token_attributes(usage)
          )
        end

        def transcription_token_attributes(usage)
          return { input_tokens: 0, output_tokens: 0 } unless usage && usage[:type].to_s == "tokens"

          raw_input = usage[:input_tokens].to_i
          audio_input = LlmCostTracker::Providers::Openai::UsageExtractor.audio_input_tokens(usage)
          {
            input_tokens: [raw_input - audio_input, 0].max,
            audio_input_tokens: audio_input,
            output_tokens: usage[:output_tokens].to_i
          }
        end

        def record_speech(_response, request:, latency_ms:, host: nil)
          record_passthrough(
            model: request[:model],
            response: nil,
            latency_ms: latency_ms,
            host: host,
            input_tokens: 0,
            output_tokens: 0,
            service_line_items: speech_line_items(request)
          )
        end

        def speech_line_items(request)
          input = request[:input]
          return [] unless input.is_a?(String)
          return [] unless LlmCostTracker::Providers::Openai::ModelFamilies.character_billed_tts?(request[:model])

          [LlmCostTracker::Charges::LineItem.build(
            dimension_key: "text_to_speech_character",
            quantity: input.length,
            cost_status: LlmCostTracker::Charges::CostStatus::UNKNOWN,
            pricing_basis: "provider_usage",
            provider_field: "request.input"
          )]
        end

        def record_moderation(response, request:, latency_ms:, host: nil)
          record_passthrough(
            model: response.model || request[:model],
            response: response,
            latency_ms: latency_ms,
            host: host,
            input_tokens: 0,
            output_tokens: 0
          )
        end

        def record_passthrough(model:, response:, latency_ms:, host: nil, service_line_items: [], **token_attributes)
          return unless active?

          record_safely do
            LlmCostTracker::Tracker.record(
              event: Event.build(
                provider: provider_for_host(host),
                model: model,
                token_usage: Usage::TokenUsage.build(**token_attributes),
                usage_source: LlmCostTracker::Usage::Source::SDK_RESPONSE,
                provider_response_id: response&.try(:id),
                service_line_items: service_line_items
              ),
              latency_ms: latency_ms
            )
          end
        end

        def usage_hash_from(response)
          response.try(:usage)&.deep_to_h
        end
      end
    end
  end
end
