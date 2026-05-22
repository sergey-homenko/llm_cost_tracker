# frozen_string_literal: true

require "spec_helper"
require "ruby_llm"

RSpec.describe LlmCostTracker::Integrations::RubyLlm do
  before { configure_sdk_integration(:ruby_llm) }

  let(:provider) { Struct.new(:slug).new("openai") }
  let(:request) { { model: "gpt-4o", stream: false } }

  describe ".record_completion" do
    it "extracts tokens from a real RubyLLM::Message" do
      message = RubyLLM::Message.new(
        role: :assistant,
        content: "hi",
        model_id: "gpt-4o",
        input_tokens: 100,
        output_tokens: 30,
        cached_tokens: 25,
        cache_creation_tokens: 5,
        thinking_tokens: 8
      )

      capture_sdk_events do |events|
        described_class.record_completion(provider, message, request: request, latency_ms: 10, has_block: false)

        expect(events.first).to include(
          provider: "openai",
          model: "gpt-4o",
          input_tokens: 75,
          output_tokens: 30,
          cache_read_input_tokens: 25,
          cache_write_input_tokens: 5,
          hidden_output_tokens: 8,
          usage_source: :sdk_response
        )
      end
    end

    it "marks the event as streaming when the caller passes a block" do
      message = RubyLLM::Message.new(role: :assistant, content: "hi", model_id: "gpt-4o",
                                     input_tokens: 5, output_tokens: 2)

      capture_sdk_events do |events|
        described_class.record_completion(provider, message, request: request, latency_ms: 1, has_block: true)
        expect(events.first[:stream]).to be(true)
      end
    end

    it "marks the event as streaming when the request payload sets stream: true" do
      message = RubyLLM::Message.new(role: :assistant, content: "hi", model_id: "gpt-4o",
                                     input_tokens: 5, output_tokens: 2)

      capture_sdk_events do |events|
        described_class.record_completion(provider, message,
                                          request: { model: "gpt-4o", stream: true },
                                          latency_ms: 1, has_block: false)
        expect(events.first[:stream]).to be(true)
      end
    end

    it "drops the event when both input_tokens and output_tokens are nil" do
      message = RubyLLM::Message.new(role: :assistant, content: "hi", model_id: "gpt-4o")
      expect(message.input_tokens).to be_nil
      expect(message.output_tokens).to be_nil

      capture_sdk_events do |events|
        described_class.record_completion(provider, message, request: request, latency_ms: 1, has_block: false)
        expect(events).to be_empty
      end
    end
  end

  describe ".record_embedding" do
    it "records embedding token usage from a real RubyLLM::Embedding" do
      embedding = RubyLLM::Embedding.new(vectors: [], model: "text-embedding-3-large", input_tokens: 30)

      capture_sdk_events do |events|
        described_class.record_embedding(provider, embedding,
                                         request: { model: "text-embedding-3-large" }, latency_ms: 5)

        expect(events.first).to include(
          provider: "openai",
          model: "text-embedding-3-large",
          input_tokens: 30,
          output_tokens: 0,
          usage_source: :sdk_response
        )
      end
    end
  end

  describe ".record_transcription" do
    it "records transcription token usage from a real RubyLLM::Transcription" do
      transcription = RubyLLM::Transcription.new(
        text: "hi",
        model: "whisper-1",
        input_tokens: 12,
        output_tokens: 3
      )

      capture_sdk_events do |events|
        described_class.record_transcription(provider, transcription,
                                             request: { model: "whisper-1" }, latency_ms: 5)

        expect(events.first).to include(
          provider: "openai",
          model: "whisper-1",
          input_tokens: 12,
          output_tokens: 3,
          usage_source: :sdk_response
        )
      end
    end
  end

  describe ".record_image" do
    it "splits image tokens from text input for a real RubyLLM::Image" do
      image = RubyLLM::Image.new(
        url: nil, data: nil, mime_type: "image/png", revised_prompt: nil,
        model_id: "gpt-image-1",
        usage: {
          input_tokens: 50, output_tokens: 100,
          input_tokens_details: { image_tokens: 30 },
          output_tokens_details: { image_tokens: 80 }
        }
      )

      capture_sdk_events do |events|
        described_class.record_image(provider, image, request: { model: "gpt-image-1" }, latency_ms: 5)

        expect(events.first).to include(
          provider: "openai",
          model: "gpt-image-1",
          input_tokens: 20,
          image_input_tokens: 30,
          output_tokens: 20,
          image_output_tokens: 80,
          usage_source: :sdk_response
        )
      end
    end

    it "records zero tokens when the image response has no usage hash" do
      image = RubyLLM::Image.new(url: "https://example.com/a.png", data: nil, mime_type: "image/png",
                                 revised_prompt: nil, model_id: "dall-e-3")

      capture_sdk_events do |events|
        described_class.record_image(provider, image, request: { model: "dall-e-3" }, latency_ms: 1)

        expect(events.first).to include(
          provider: "openai", model: "dall-e-3", input_tokens: 0, output_tokens: 0,
          image_input_tokens: 0, image_output_tokens: 0
        )
      end
    end
  end

  describe ".record_moderation" do
    it "records moderation as a zero-token event from a real RubyLLM::Moderation" do
      moderation = RubyLLM::Moderation.new(id: "modr_xyz", model: "omni-moderation-latest", results: [])

      capture_sdk_events do |events|
        described_class.record_moderation(provider, moderation,
                                          request: { model: "omni-moderation-latest" }, latency_ms: 5)

        expect(events.first).to include(
          provider: "openai",
          model: "omni-moderation-latest",
          input_tokens: 0,
          output_tokens: 0,
          provider_response_id: "modr_xyz"
        )
      end
    end
  end

  describe "ProviderPatch end-to-end through wrap_blocking_call" do
    let(:patched_provider_class) do
      Class.new do
        def slug = "openai"

        def complete(_messages, **)
          RubyLLM::Message.new(role: :assistant, content: "hi", model_id: "gpt-4o",
                               input_tokens: 8, output_tokens: 4, cached_tokens: 3)
        end

        def embed(_text, **)
          RubyLLM::Embedding.new(vectors: [], model: "text-embedding-3-large", input_tokens: 7)
        end

        def transcribe(_audio_file, **)
          RubyLLM::Transcription.new(text: "hi", model: "whisper-1", input_tokens: 6, output_tokens: 2)
        end

        def paint(_prompt, **)
          RubyLLM::Image.new(url: nil, data: nil, mime_type: "image/png", revised_prompt: nil,
                             model_id: "gpt-image-1",
                             usage: { input_tokens: 6, output_tokens: 0,
                                      input_tokens_details: { image_tokens: 4 } })
        end

        def moderate(_input, **)
          RubyLLM::Moderation.new(id: "modr_p", model: "omni-moderation-latest", results: [])
        end

        prepend LlmCostTracker::Integrations::RubyLlm::ProviderPatch
      end
    end

    it "dispatches complete through the patch to record_completion with stream=false" do
      capture_sdk_events do |events|
        result = patched_provider_class.new.complete([], tools: [], temperature: 0.7, model: "gpt-4o")

        expect(result).to be_a(RubyLLM::Message)
        expect(events.first).to include(
          provider: "openai", model: "gpt-4o",
          input_tokens: 5, output_tokens: 4, cache_read_input_tokens: 3,
          stream: false, usage_source: :sdk_response
        )
      end
    end

    it "forwards block_given? to record_completion as the stream flag" do
      capture_sdk_events do |events|
        patched_provider_class.new.complete([], tools: [], temperature: 0.7, model: "gpt-4o") { |_| }
        expect(events.first[:stream]).to be(true)
      end
    end

    it "dispatches embed through the patch to record_embedding with zero output_tokens" do
      capture_sdk_events do |events|
        patched_provider_class.new.embed("hi", model: "text-embedding-3-large", dimensions: nil)

        expect(events.first).to include(
          provider: "openai", model: "text-embedding-3-large",
          input_tokens: 7, output_tokens: 0, usage_source: :sdk_response
        )
      end
    end

    it "dispatches transcribe through the patch to record_transcription" do
      capture_sdk_events do |events|
        patched_provider_class.new.transcribe(nil, model: "whisper-1", language: "en")

        expect(events.first).to include(
          provider: "openai", model: "whisper-1",
          input_tokens: 6, output_tokens: 2, usage_source: :sdk_response
        )
      end
    end

    it "dispatches paint through the patch to record_image with image-token splits" do
      capture_sdk_events do |events|
        patched_provider_class.new.paint("a cat", model: "gpt-image-1", size: "1024x1024")

        expect(events.first).to include(
          provider: "openai", model: "gpt-image-1",
          input_tokens: 2, image_input_tokens: 4, usage_source: :sdk_response
        )
      end
    end

    it "dispatches moderate through the patch to record_moderation as a zero-token event" do
      capture_sdk_events do |events|
        patched_provider_class.new.moderate("hello", model: "omni-moderation-latest")

        expect(events.first).to include(
          provider: "openai", model: "omni-moderation-latest",
          input_tokens: 0, output_tokens: 0, provider_response_id: "modr_p"
        )
      end
    end
  end
end
