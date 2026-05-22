# frozen_string_literal: true

require_relative "base"
require_relative "../billing/line_item"
require_relative "../providers/azure/hosts"
require_relative "../providers/openai/model_families"
require_relative "../providers/openai/service_charges"
require_relative "../providers/openai/usage_extractor"

module LlmCostTracker
  module Integrations
    module Openai # rubocop:disable Metrics/ModuleLength
      extend Base

      class << self
        def integration_name
          :openai
        end

        def stream_pricing_mode(request, host: nil)
          LlmCostTracker::Parsers::OpenaiUsage.combined_pricing_mode(
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

        def wrap_stream_call(args, kwargs, resource)
          request = request_params(args, kwargs)
          enforce_budget!(request: request)
          host = client_host_for(resource)
          collector = stream_collector(request, host: host)
          stream = yield(normalize_sdk_args(args, kwargs), collector)
          track_stream(stream, collector: collector)
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

        def minimum_version
          "0.59.0"
        end

        def version_constant
          "OpenAI::VERSION"
        end

        def patch_targets
          [
            patch_target("OpenAI::Resources::Responses",
                         with: ResponsesPatch, methods: %i[create stream stream_raw retrieve_streaming]),
            patch_target("OpenAI::Resources::Chat::Completions",
                         with: ChatCompletionsPatch, methods: %i[create stream stream_raw]),
            *auxiliary_patch_targets
          ]
        end

        def auxiliary_patch_targets
          [
            patch_target("OpenAI::Resources::Embeddings",
                         with: EmbeddingsPatch, methods: %i[create], optional: true),
            patch_target("OpenAI::Resources::Images",
                         with: ImagesPatch, methods: %i[generate edit create_variation], optional: true),
            patch_target("OpenAI::Resources::Images",
                         with: StreamingImagesPatch,
                         methods: %i[generate_stream_raw edit_stream_raw],
                         optional: true, skip_when_methods_missing: true),
            patch_target("OpenAI::Resources::Audio::Transcriptions",
                         with: TranscriptionsPatch, methods: %i[create], optional: true),
            patch_target("OpenAI::Resources::Audio::Transcriptions",
                         with: StreamingTranscriptionsPatch,
                         methods: %i[create_streaming],
                         optional: true, skip_when_methods_missing: true),
            patch_target("OpenAI::Resources::Audio::Translations",
                         with: TranslationsPatch, methods: %i[create], optional: true),
            patch_target("OpenAI::Resources::Audio::Speech",
                         with: SpeechPatch, methods: %i[create], optional: true),
            patch_target("OpenAI::Resources::Moderations",
                         with: ModerationsPatch, methods: %i[create], optional: true)
          ]
        end

        def record_response(response, request:, latency_ms:, host: nil)
          return unless active?

          record_safely do
            usage = usage_hash_from(response)
            next unless usage

            input_tokens = usage[:input_tokens] || usage[:prompt_tokens]
            output_tokens = usage[:output_tokens] || usage[:completion_tokens]
            next if input_tokens.nil? && output_tokens.nil?

            model = response.model || request[:model]
            service_tier = response.try(:service_tier) || request[:service_tier]

            LlmCostTracker::Tracker.record(
              event: Event.build(
                provider: provider_for_host(host),
                model: model,
                pricing_mode: LlmCostTracker::Parsers::OpenaiUsage.combined_pricing_mode(
                  host: host, model: model, service_tier: service_tier
                ),
                token_usage: LlmCostTracker::Providers::Openai::UsageExtractor.token_usage(usage, model: model),
                usage_source: :sdk_response,
                provider_response_id: response.try(:id),
                service_line_items: service_line_items_from(response, request: request)
              ),
              latency_ms: latency_ms
            )
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
          record_passthrough(
            model: request[:model],
            response: response,
            latency_ms: latency_ms,
            host: host,
            **transcription_token_attributes(usage_hash_from(response))
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

          [LlmCostTracker::Billing::LineItem.build(
            component_key: :text_to_speech_character,
            quantity: input.length,
            cost_status: LlmCostTracker::Billing::CostStatus::UNKNOWN,
            pricing_basis: :provider_usage,
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
                token_usage: TokenUsage.build(**token_attributes),
                usage_source: :sdk_response,
                provider_response_id: response&.try(:id),
                service_line_items: service_line_items
              ),
              latency_ms: latency_ms
            )
          end
        end

        def service_line_items_from(response, request: nil)
          model = response_field(response, :model) || request&.dig(:model)
          output = response_field(response, :output)
          output_items = Array(output).map { |item| normalize_output_item(item) }.compact
          chat_search = output_items.empty? ? chat_completions_search_item(response, model: model) : nil
          output_items << chat_search if chat_search
          return [] if output_items.empty?

          LlmCostTracker::Providers::Openai::ServiceCharges.line_items_from_output(
            output_items, request: request, model: model
          )
        end

        def chat_completions_search_item(response, model: nil)
          choices = response_field(response, :choices)
          return nil if choices.nil?

          provider_field = if choices.any? { |choice| choice_used_url_citation?(choice) }
                             LlmCostTracker::Providers::Openai::ServiceCharges::CHAT_COMPLETIONS_ANNOTATION_PROVIDER_FIELD
                           elsif LlmCostTracker::Providers::Openai::ModelFamilies.chat_completions_search?(model)
                             LlmCostTracker::Providers::Openai::ServiceCharges::CHAT_COMPLETIONS_SEARCH_MODEL_PROVIDER_FIELD
                           end
          return nil unless provider_field

          { "type" => "web_search_call", "id" => response_field(response, :id),
            "action" => { "type" => "search" }, "provider_field" => provider_field }
        end

        def choice_used_url_citation?(choice)
          message = response_field(choice, :message)
          annotations = response_field(message, :annotations)
          return false if annotations.nil?

          annotations.any? { |annotation| response_field(annotation, :type).to_s == "url_citation" }
        end

        def normalize_output_item(item)
          return nil if item.nil?

          hash = (item.is_a?(Hash) ? item : item.deep_to_h).deep_stringify_keys
          hash["type"] = hash["type"]&.to_s
          hash["status"] = hash["status"]&.to_s if hash.key?("status")
          hash["action"] = hash["action"].merge("type" => hash["action"]["type"]&.to_s) if hash["action"].is_a?(Hash)
          hash
        end

        def response_field(object, key)
          return nil if object.nil?
          return object[key] || object[key.to_s] if object.is_a?(Hash)

          object.try(key)
        end

        def usage_hash_from(response)
          usage = response&.try(:usage)
          return nil unless usage
          return usage.deep_symbolize_keys if usage.is_a?(Hash)

          usage.deep_to_h
        end
      end

      module PatchBuilder
        module_function

        def build(record_method:, methods:)
          Module.new.tap do |mod|
            methods.each { |method_name| define_blocking_method(mod, method_name, record_method) }
          end
        end

        def build_stream(methods:)
          Module.new.tap do |mod|
            methods.each { |method_name| define_stream_method(mod, method_name) }
          end
        end

        def define_blocking_method(mod, method_name, record_method)
          mod.define_method(method_name) do |*args, **kwargs, &block|
            integration = LlmCostTracker::Integrations::Openai
            request = integration.request_params(args, kwargs)
            integration.enforce_budget!(request: request)
            started_at = LlmCostTracker::Timing.now_monotonic
            response = super(*integration.normalize_sdk_args(args, kwargs), &block)
            integration.public_send(
              record_method, response,
              request: request,
              latency_ms: LlmCostTracker::Timing.elapsed_ms(started_at),
              host: integration.client_host_for(self)
            )
            response
          end
        end

        def define_stream_method(mod, method_name)
          mod.define_method(method_name) do |*args, **kwargs|
            LlmCostTracker::Integrations::Openai.wrap_stream_call(args, kwargs, self) do |normalized, _|
              super(*normalized)
            end
          end
        end
      end

      module ResponsesPatch
        include PatchBuilder.build(record_method: :record_response, methods: %i[create])
        include PatchBuilder.build_stream(methods: %i[stream stream_raw])

        def retrieve_streaming(response_id, *args, **kwargs)
          LlmCostTracker::Integrations::Openai.wrap_stream_call(args, kwargs, self) do |normalized, collector|
            collector.provider_response_id = response_id
            super(response_id, *normalized)
          end
        end
      end

      module ChatCompletionsPatch
        include PatchBuilder.build(record_method: :record_response, methods: %i[create])
        include PatchBuilder.build_stream(methods: %i[stream stream_raw])
      end

      EmbeddingsPatch = PatchBuilder.build(record_method: :record_response, methods: %i[create])
      ImagesPatch = PatchBuilder.build(record_method: :record_image, methods: %i[generate edit create_variation])
      TranscriptionsPatch = PatchBuilder.build(record_method: :record_transcription, methods: %i[create])
      TranslationsPatch = PatchBuilder.build(record_method: :record_transcription, methods: %i[create])
      SpeechPatch = PatchBuilder.build(record_method: :record_speech, methods: %i[create])
      ModerationsPatch = PatchBuilder.build(record_method: :record_moderation, methods: %i[create])
      StreamingImagesPatch = PatchBuilder.build_stream(methods: %i[generate_stream_raw edit_stream_raw])
      StreamingTranscriptionsPatch = PatchBuilder.build_stream(methods: %i[create_streaming])
    end
  end
end
