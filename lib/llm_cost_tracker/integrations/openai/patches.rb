# frozen_string_literal: true

module LlmCostTracker
  module Integrations
    module Openai
      module PatchBuilder
        def self.build(record_method:, methods:)
          Module.new.tap do |mod|
            methods.each { |method_name| define_blocking_method(mod, method_name, record_method) }
          end
        end

        def self.build_stream(methods:)
          Module.new.tap do |mod|
            methods.each { |method_name| define_stream_method(mod, method_name) }
          end
        end

        def self.define_blocking_method(mod, method_name, record_method)
          mod.define_method(method_name) do |*args, **kwargs, &block|
            host = LlmCostTracker::Integrations::Openai.client_host_for(self)
            LlmCostTracker::Integrations::Openai.wrap_blocking(
              args,
              kwargs,
              provider: LlmCostTracker::Integrations::Openai.provider_for_host(host),
              record: lambda do |response, request, latency_ms|
                LlmCostTracker::Integrations::Openai.public_send(
                  record_method, response, request: request, latency_ms: latency_ms, host: host
                )
              end
            ) { super(*args, **kwargs, &block) }
          end
        end

        def self.define_stream_method(mod, method_name)
          mod.define_method(method_name) do |*args, **kwargs|
            LlmCostTracker::Integrations::Openai.wrap_stream(
              args, kwargs, **LlmCostTracker::Integrations::Openai.stream_seam(self)
            ) { super(*args, **kwargs) }
          end
        end
      end

      module ResponsesPatch
        include PatchBuilder.build(record_method: :record_response, methods: %i[create])
        include PatchBuilder.build_stream(methods: %i[stream stream_raw])

        def retrieve_streaming(response_id, *args, **kwargs)
          LlmCostTracker::Integrations::Openai.wrap_stream(
            args, kwargs, **LlmCostTracker::Integrations::Openai.stream_seam(self)
          ) do |collector|
            collector.provider_response_id = response_id
            super(response_id, *args, **kwargs)
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

      module BatchesPatch
        def retrieve(batch_id, *args, **kwargs)
          batch = super
          LlmCostTracker::Integrations::Openai::BatchCapture.maybe_capture(batch, resource: self)
          batch
        end
      end
    end
  end
end
