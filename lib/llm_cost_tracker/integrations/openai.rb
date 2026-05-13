# frozen_string_literal: true

require_relative "base"
require_relative "../billing/line_item"
require_relative "../parsers/openai_service_charges"
require_relative "../providers/azure/hosts"

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

        def client_host_for(resource)
          client = resource.instance_variable_get(:@client)
          return nil unless client.respond_to?(:base_url, true)

          URI.parse(client.send(:base_url).to_s).host
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
            usage = object_value(response, :usage)
            next unless usage

            input_tokens = object_value(usage, :input_tokens, :prompt_tokens)
            output_tokens = object_value(usage, :output_tokens, :completion_tokens)
            next if input_tokens.nil? && output_tokens.nil?

            cache_read = cache_read_input_tokens(usage)
            model = object_value(response, :model) || request[:model]
            LlmCostTracker::Tracker.record(
              capture: UsageCapture.build(
                provider: provider_for_host(host),
                model: model,
                pricing_mode: LlmCostTracker::Parsers::OpenaiUsage.combined_pricing_mode(
                  host: host,
                  model: model,
                  service_tier: object_value(response, :service_tier) || request[:service_tier]
                ),
                token_usage: token_usage(usage:, input_tokens:, output_tokens:, cache_read:, model: model),
                usage_source: :sdk_response,
                provider_response_id: object_value(response, :id),
                service_line_items: service_line_items_from(response, request: request)
              ),
              latency_ms: latency_ms
            )
          end
        end

        def record_image(response, request:, latency_ms:, host: nil)
          usage = object_value(response, :usage)
          raw_input = usage ? object_value(usage, :input_tokens).to_i : 0
          raw_output = usage ? object_value(usage, :output_tokens).to_i : 0
          image_input = image_input_tokens(usage).to_i
          cache_read = cache_read_input_tokens(usage).to_i
          text_input = [raw_input - image_input - cache_read, 0].max
          image_output, text_output = split_image_output(usage, raw_output)
          record_passthrough(
            model: request[:model],
            response: response,
            latency_ms: latency_ms,
            host: host,
            input_tokens: text_input,
            image_input_tokens: image_input,
            output_tokens: text_output,
            image_output_tokens: image_output,
            cache_read_input_tokens: cache_read
          )
        end

        def split_image_output(usage, raw_output)
          image_tokens = image_output_tokens(usage).to_i
          text_tokens = text_output_tokens(usage).to_i
          return [raw_output, 0] if image_tokens.zero? && text_tokens.zero?

          text_tokens = [raw_output - image_tokens, 0].max if text_tokens.zero?
          [image_tokens, text_tokens]
        end

        def record_transcription(response, request:, latency_ms:, host: nil)
          record_passthrough(
            model: request[:model],
            response: response,
            latency_ms: latency_ms,
            host: host,
            **transcription_token_attributes(object_value(response, :usage))
          )
        end

        def transcription_token_attributes(usage)
          return { input_tokens: 0, output_tokens: 0 } unless usage && object_value(usage, :type).to_s == "tokens"

          raw_input = object_value(usage, :input_tokens).to_i
          audio_input = object_dig(usage, :input_token_details, :audio_tokens).to_i
          {
            input_tokens: [raw_input - audio_input, 0].max,
            audio_input_tokens: audio_input,
            output_tokens: object_value(usage, :output_tokens).to_i
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

        CHARACTER_BILLED_TTS_MODELS = /\Atts-1(-hd)?\z/
        private_constant :CHARACTER_BILLED_TTS_MODELS

        def speech_line_items(request)
          input = request[:input]
          return [] unless input.is_a?(String)
          return [] unless CHARACTER_BILLED_TTS_MODELS.match?(request[:model].to_s)

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
            model: object_value(response, :model) || request[:model],
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
              capture: UsageCapture.build(
                provider: provider_for_host(host),
                model: model,
                token_usage: TokenUsage.build(**token_attributes),
                usage_source: :sdk_response,
                provider_response_id: response && object_value(response, :id),
                service_line_items: service_line_items
              ),
              latency_ms: latency_ms
            )
          end
        end

        def service_line_items_from(response, request: nil)
          output = object_value(response, :output)
          return [] unless output.respond_to?(:each)

          LlmCostTracker::Parsers::OpenaiServiceCharges.line_items_from_output(
            output.map { |item| normalize_output_item(item) },
            request: request,
            model: object_value(response, :model) || request&.dig(:model)
          )
        end

        def normalize_output_item(item)
          return item if item.is_a?(Hash)
          return nil if item.nil?

          {
            "type" => object_value(item, :type)&.to_s,
            "id" => object_value(item, :id),
            "status" => object_value(item, :status),
            "container_id" => object_value(item, :container_id),
            "action" => normalize_output_action(object_value(item, :action))
          }
        end

        def normalize_output_action(action)
          return nil if action.nil?
          return action if action.is_a?(Hash)

          { "type" => object_value(action, :type)&.to_s }
        end

        IMAGE_OUTPUT_MODEL_PATTERN = /\Agpt-image-/i
        private_constant :IMAGE_OUTPUT_MODEL_PATTERN

        def token_usage(usage:, input_tokens:, output_tokens:, cache_read:, model: nil)
          audio_input = audio_input_tokens(usage)
          audio_output = audio_output_tokens(usage)
          image_input = image_input_tokens(usage)
          image_output_details = image_output_tokens(usage)
          text_output_details = text_output_tokens(usage)
          image_output, regular_output = split_responses_image_output(
            output_tokens: output_tokens.to_i,
            image_output_details: image_output_details,
            text_output_details: text_output_details,
            audio_output: audio_output,
            default_to_image: model.to_s.match?(IMAGE_OUTPUT_MODEL_PATTERN)
          )

          TokenUsage.build(
            input_tokens: regular_input_tokens(input_tokens, cache_read, audio_input, image_input),
            output_tokens: regular_output,
            cache_read_input_tokens: cache_read,
            audio_input_tokens: audio_input,
            audio_output_tokens: audio_output,
            image_input_tokens: image_input,
            image_output_tokens: image_output,
            hidden_output_tokens: hidden_output_tokens(usage)
          )
        end

        INPUT_DETAIL_KEYS = %i[input_tokens_details input_token_details prompt_tokens_details].freeze
        OUTPUT_DETAIL_KEYS = %i[output_tokens_details output_token_details completion_tokens_details].freeze

        def cache_read_input_tokens(usage) = detail(usage, INPUT_DETAIL_KEYS, :cached_tokens)
        def hidden_output_tokens(usage)    = detail(usage, OUTPUT_DETAIL_KEYS, :reasoning_tokens)
        def audio_input_tokens(usage)      = detail(usage, INPUT_DETAIL_KEYS, :audio_tokens)
        def audio_output_tokens(usage)     = detail(usage, OUTPUT_DETAIL_KEYS, :audio_tokens)
        def image_input_tokens(usage)      = detail(usage, INPUT_DETAIL_KEYS, :image_tokens)
        def image_output_tokens(usage)     = detail(usage, OUTPUT_DETAIL_KEYS, :image_tokens)
        def text_output_tokens(usage)      = detail(usage, OUTPUT_DETAIL_KEYS, :text_tokens)

        def detail(usage, containers, key)
          containers.each do |container|
            value = object_dig(usage, container, key)
            return value.to_i if value
          end
          0
        end

        def regular_input_tokens(input_tokens, cache_read, audio_input, image_input)
          [input_tokens.to_i - cache_read - audio_input - image_input, 0].max
        end

        def split_responses_image_output(output_tokens:, image_output_details:, text_output_details:, audio_output:,
                                         default_to_image: false)
          if image_output_details.zero? && text_output_details.zero?
            remainder = [output_tokens - audio_output, 0].max
            return default_to_image ? [remainder, 0] : [0, remainder]
          end

          text_output = text_output_details
          text_output = [output_tokens - image_output_details - audio_output, 0].max if text_output.zero?
          [image_output_details, text_output]
        end
      end

      module ResponsesPatch
        def create(*args, **kwargs)
          LlmCostTracker::Integrations::Openai.enforce_budget!
          started_at = LlmCostTracker::Timing.now_monotonic
          response = super(*LlmCostTracker::Integrations::Openai.normalize_sdk_args(args, kwargs))
          LlmCostTracker::Integrations::Openai.record_response(
            response,
            request: LlmCostTracker::Integrations::Openai.request_params(args, kwargs),
            latency_ms: LlmCostTracker::Integrations::Openai.elapsed_ms(started_at),
            host: LlmCostTracker::Integrations::Openai.client_host_for(self)
          )
          response
        end

        def stream(*args, **kwargs)
          request = LlmCostTracker::Integrations::Openai.request_params(args, kwargs)
          LlmCostTracker::Integrations::Openai.enforce_budget!
          host = LlmCostTracker::Integrations::Openai.client_host_for(self)
          collector = LlmCostTracker::Integrations::Openai.stream_collector(request, host: host)
          stream = super(*LlmCostTracker::Integrations::Openai.normalize_sdk_args(args, kwargs))
          LlmCostTracker::Integrations::Openai.track_stream(stream, collector: collector)
        end

        def stream_raw(*args, **kwargs)
          request = LlmCostTracker::Integrations::Openai.request_params(args, kwargs)
          LlmCostTracker::Integrations::Openai.enforce_budget!
          host = LlmCostTracker::Integrations::Openai.client_host_for(self)
          collector = LlmCostTracker::Integrations::Openai.stream_collector(request, host: host)
          stream = super(*LlmCostTracker::Integrations::Openai.normalize_sdk_args(args, kwargs))
          LlmCostTracker::Integrations::Openai.track_stream(stream, collector: collector)
        end

        def retrieve_streaming(response_id, *args, **kwargs)
          request = LlmCostTracker::Integrations::Openai.request_params(args, kwargs)
          LlmCostTracker::Integrations::Openai.enforce_budget!
          host = LlmCostTracker::Integrations::Openai.client_host_for(self)
          collector = LlmCostTracker::Integrations::Openai.stream_collector(request, host: host)
          collector.provider_response_id = response_id
          stream = super(response_id, *LlmCostTracker::Integrations::Openai.normalize_sdk_args(args, kwargs))
          LlmCostTracker::Integrations::Openai.track_stream(stream, collector: collector)
        end
      end

      module ChatCompletionsPatch
        def create(*args, **kwargs)
          LlmCostTracker::Integrations::Openai.enforce_budget!
          started_at = LlmCostTracker::Timing.now_monotonic
          response = super(*LlmCostTracker::Integrations::Openai.normalize_sdk_args(args, kwargs))
          LlmCostTracker::Integrations::Openai.record_response(
            response,
            request: LlmCostTracker::Integrations::Openai.request_params(args, kwargs),
            latency_ms: LlmCostTracker::Integrations::Openai.elapsed_ms(started_at),
            host: LlmCostTracker::Integrations::Openai.client_host_for(self)
          )
          response
        end

        def stream(*args, **kwargs)
          request = LlmCostTracker::Integrations::Openai.request_params(args, kwargs)
          LlmCostTracker::Integrations::Openai.enforce_budget!
          host = LlmCostTracker::Integrations::Openai.client_host_for(self)
          collector = LlmCostTracker::Integrations::Openai.stream_collector(request, host: host)
          stream = super(*LlmCostTracker::Integrations::Openai.normalize_sdk_args(args, kwargs))
          LlmCostTracker::Integrations::Openai.track_stream(stream, collector: collector)
        end

        def stream_raw(*args, **kwargs)
          request = LlmCostTracker::Integrations::Openai.request_params(args, kwargs)
          LlmCostTracker::Integrations::Openai.enforce_budget!
          host = LlmCostTracker::Integrations::Openai.client_host_for(self)
          collector = LlmCostTracker::Integrations::Openai.stream_collector(request, host: host)
          stream = super(*LlmCostTracker::Integrations::Openai.normalize_sdk_args(args, kwargs))
          LlmCostTracker::Integrations::Openai.track_stream(stream, collector: collector)
        end
      end

      module PatchBuilder
        module_function

        def build(record_method:, methods:)
          Module.new.tap do |mod|
            methods.each { |method_name| define_wrapped_method(mod, method_name, record_method) }
          end
        end

        def define_wrapped_method(mod, method_name, record_method)
          mod.define_method(method_name) do |*args, **kwargs, &block|
            integration = LlmCostTracker::Integrations::Openai
            integration.enforce_budget!
            started_at = LlmCostTracker::Timing.now_monotonic
            response = super(*integration.normalize_sdk_args(args, kwargs), &block)
            integration.public_send(
              record_method, response,
              request: integration.request_params(args, kwargs),
              latency_ms: integration.elapsed_ms(started_at),
              host: integration.client_host_for(self)
            )
            response
          end
        end
      end

      EmbeddingsPatch = PatchBuilder.build(record_method: :record_response, methods: %i[create])
      ImagesPatch = PatchBuilder.build(record_method: :record_image, methods: %i[generate edit create_variation])
      TranscriptionsPatch = PatchBuilder.build(record_method: :record_transcription, methods: %i[create])
      TranslationsPatch = PatchBuilder.build(record_method: :record_transcription, methods: %i[create])
      SpeechPatch = PatchBuilder.build(record_method: :record_speech, methods: %i[create])
      ModerationsPatch = PatchBuilder.build(record_method: :record_moderation, methods: %i[create])

      module StreamingImagesPatch
        %i[generate_stream_raw edit_stream_raw].each do |method_name|
          define_method(method_name) do |*args, **kwargs|
            request = LlmCostTracker::Integrations::Openai.request_params(args, kwargs)
            LlmCostTracker::Integrations::Openai.enforce_budget!
            host = LlmCostTracker::Integrations::Openai.client_host_for(self)
            collector = LlmCostTracker::Integrations::Openai.stream_collector(request, host: host)
            stream = super(*LlmCostTracker::Integrations::Openai.normalize_sdk_args(args, kwargs))
            LlmCostTracker::Integrations::Openai.track_stream(stream, collector: collector)
          end
        end
      end

      module StreamingTranscriptionsPatch
        def create_streaming(*args, **kwargs)
          request = LlmCostTracker::Integrations::Openai.request_params(args, kwargs)
          LlmCostTracker::Integrations::Openai.enforce_budget!
          host = LlmCostTracker::Integrations::Openai.client_host_for(self)
          collector = LlmCostTracker::Integrations::Openai.stream_collector(request, host: host)
          stream = super(*LlmCostTracker::Integrations::Openai.normalize_sdk_args(args, kwargs))
          LlmCostTracker::Integrations::Openai.track_stream(stream, collector: collector)
        end
      end
    end
  end
end
