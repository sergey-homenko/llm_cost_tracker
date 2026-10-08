# frozen_string_literal: true

module LlmCostTracker
  module Integrations
    module Openai
      module PatchBuilder
        def self.build(record_method:, methods:)
          Module.new.tap do |patch|
            methods.each do |method_name|
              patch.define_method(method_name) do |*args, **kwargs, &block|
                seam = Openai.blocking_seam(@client, record_method)
                Openai.wrap_blocking(args, kwargs, **seam) { super(*args, **kwargs, &block) }
              end
            end
          end
        end

        def self.build_stream(methods:)
          Module.new.tap do |patch|
            methods.each do |method_name|
              patch.define_method(method_name) do |*args, **kwargs|
                Openai.wrap_stream(args, kwargs, **Openai.stream_seam(@client)) { super(*args, **kwargs) }
              end
            end
          end
        end
      end

      module ResponsesPatch
        include PatchBuilder.build(record_method: :record_response, methods: %i[create compact])
        include PatchBuilder.build_stream(methods: %i[stream stream_raw])

        def retrieve(response_id, *args, **kwargs)
          super.tap { |response| Openai.record_retrieved_response(response, host: Openai.client_host(@client)) }
        end

        def retrieve_streaming(response_id, *args, **kwargs)
          Openai.wrap_stream(args, kwargs, **Openai.stream_seam(@client)) do |collector|
            collector.provider_response_id = response_id
            super(response_id, *args, **kwargs)
          end
        end
      end

      module ResponsesConnectionPatch
        def send_event(event)
          llm_cost_tracker_capture.sending(event) { super }
        end

        def each(&block)
          return super unless block

          capture = llm_cost_tracker_capture
          capture.reading do
            super do |event|
              capture.track(event)
              block.call(event)
            end
          end
        end

        def receive
          llm_cost_tracker_capture.raise_deferred
          super.tap { |event| llm_cost_tracker_capture.track(event) }
        end

        private

        def llm_cost_tracker_capture
          @llm_cost_tracker_capture ||= WebsocketCapture.new(url)
        end
      end

      module ChatCompletionsPatch
        include PatchBuilder.build(record_method: :record_response, methods: %i[create])
        include PatchBuilder.build_stream(methods: %i[stream stream_raw])
      end

      CreatePatch = PatchBuilder.build(record_method: :record_response, methods: %i[create])
      ImagesPatch = PatchBuilder.build(record_method: :record_image, methods: %i[generate edit create_variation])
      TranscriptionsPatch = PatchBuilder.build(record_method: :record_transcription, methods: %i[create])
      TranslationsPatch = PatchBuilder.build(record_method: :record_transcription, methods: %i[create])
      SpeechPatch = PatchBuilder.build(record_method: :record_speech, methods: %i[create])
      ModerationsPatch = PatchBuilder.build(record_method: :record_moderation, methods: %i[create])
      StreamingImagesPatch = PatchBuilder.build_stream(methods: %i[generate_stream_raw edit_stream_raw])
      StreamingTranscriptionsPatch = PatchBuilder.build_stream(methods: %i[create_streaming])

      module BatchesPatch
        def create(*args, **kwargs)
          Openai.enforce_budget!(request: Openai.request_params(args, kwargs))
          super
        end

        def retrieve(batch_id, *args, **kwargs)
          super.tap { |batch| BatchCapture.capture(batch, client: @client) }
        end
      end
    end
  end
end
