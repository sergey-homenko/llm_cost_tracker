# frozen_string_literal: true

module LlmCostTracker
  module Integrations
    module RubyLlm
      module V2
        SEAMS = {
          build_chunk: %w[Protocols::Anthropic Protocols::ChatCompletions Protocols::Responses Protocols::Gemini
                          Protocols::Interactions Protocols::Converse Providers::OpenRouter::ChatCompletions
                          Protocols::Cohere],
          parse_completion_body: %w[Protocols::Anthropic Protocols::ChatCompletions Protocols::Responses
                                    Protocols::Gemini Protocols::Interactions Protocols::Converse
                                    Protocols::Mistral::Conversations Providers::Mistral::ChatCompletions],
          parse_embedding_response: %w[Protocols::ChatCompletions Protocols::Gemini Providers::VertexAI::EmbedContent
                                       Providers::Perplexity::Embeddings Protocols::Cohere],
          parse_transcription_response: %w[Protocols::ChatCompletions Protocols::Gemini],
          parse_speech_response: %w[Protocols::Gemini],
          stream_transcription: %w[Protocols::ChatCompletions],
          transcribe: %w[Protocol Protocols::Deepgram Protocols::Gemini::LiveTranscription],
          parse_image_responses: %w[Protocols::ChatCompletions Protocols::Gemini Providers::XAI::Images],
          parse_cache_response: %w[Protocols::Gemini],
          messages: %w[Batch],
          results: %w[Batch],
          current_workflow: %w[Support::Instrumentation]
        }.freeze
        StreamTranscriptionBridge = Module.new do
          def stream_transcription(*, **, &block)
            super do |chunk|
              V2.observe(:stream_transcription, chunk.raw, self)
              block.call(chunk)
            end
          end
        end
        TranscribeBridge = Module.new do
          def transcribe(*, **, &block)
            V2.observe(:transcribe, {}, self) if block
            super
          end
        end
        BatchBridge = Module.new do
          %i[messages results].each { |name| define_method(name) { V2.collect(self) { super() } } }
        end
        BRIDGES = (SEAMS.keys - %i[stream_transcription transcribe messages results current_workflow]).to_h do |seam|
          bridge = Module.new do
            define_method(seam) do |value, *args, **options, &block|
              V2.observe(seam, options.fetch(:raw, value), self)
              super(value, *args, **options, &block)
            end
          end
          [seam, const_set("#{seam.to_s.camelize}Bridge", bridge)]
        end.merge(
          stream_transcription: StreamTranscriptionBridge,
          transcribe: TranscribeBridge,
          messages: BatchBridge,
          results: BatchBridge
        ).freeze

        module Seams
          class << self
            def bridge
              BRIDGES.each do |seam, bridge|
                SEAMS[seam].filter_map { |target| owner(target, seam) }.each do |owner|
                  owner.prepend(bridge) unless owner == bridge
                end
              end
            end

            def missing
              SEAMS.flat_map do |seam, targets|
                targets.reject { |target| owner(target, seam) }.map { |target| "RubyLLM::#{target}##{seam}" }
              end
            end

            private

            def owner(target, seam)
              "RubyLLM::#{target}".safe_constantize&.instance_method(seam)&.owner
            rescue NameError
              nil
            end
          end
        end
      end
    end
  end
end
