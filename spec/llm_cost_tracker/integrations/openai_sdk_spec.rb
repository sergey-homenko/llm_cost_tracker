# frozen_string_literal: true

require "spec_helper"
require "openai"
require "stringio"

RSpec.describe LlmCostTracker::Integrations::Openai do
  before { configure_sdk_integration(:openai) }

  let(:client) { OpenAI::Client.new(api_key: "test-key") }
  let(:audio_io) { StringIO.new("RIFF").tap { |io| io.set_encoding(Encoding::BINARY) } }

  describe "responses.create" do
    it "records token usage with cached and reasoning breakdowns" do
      stub_sdk_json(:post, "https://api.openai.com/v1/responses",
                    provider: :openai, fixture: "responses_create.json")

      capture_sdk_events do |events|
        response = client.responses.create(model: "gpt-4o", input: "hi")

        expect(response).to be_a(OpenAI::Models::Responses::Response)
        expect(events.first).to include(
          provider: "openai",
          model: "gpt-4o",
          input_tokens: 40,
          output_tokens: 25,
          cache_read_input_tokens: 10,
          hidden_output_tokens: 5,
          usage_source: :sdk_response,
          provider_response_id: "resp_abc"
        )
      end
    end
  end

  describe "chat.completions.create" do
    it "records token usage with prompt/completion field mapping and cached split" do
      stub_sdk_json(:post, "https://api.openai.com/v1/chat/completions",
                    provider: :openai, fixture: "chat_completions_create.json")

      capture_sdk_events do |events|
        response = client.chat.completions.create(
          model: "gpt-4o",
          messages: [{ role: "user", content: "hi" }]
        )

        expect(response).to be_a(OpenAI::Models::Chat::ChatCompletion)
        expect(events.first).to include(
          provider: "openai",
          model: "gpt-4o",
          input_tokens: 40,
          output_tokens: 25,
          cache_read_input_tokens: 10,
          usage_source: :sdk_response,
          provider_response_id: "chatcmpl_xyz"
        )
      end
    end
  end

  describe "embeddings.create" do
    it "records token usage for embeddings" do
      stub_sdk_json(:post, "https://api.openai.com/v1/embeddings",
                    provider: :openai, fixture: "embeddings_create.json")

      capture_sdk_events do |events|
        client.embeddings.create(model: "text-embedding-3-large", input: "hi")

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

  describe "images.generate" do
    it "records image tokens split from text input on real SDK response" do
      stub_sdk_json(:post, "https://api.openai.com/v1/images/generations",
                    provider: :openai, fixture: "images_generate.json")

      capture_sdk_events do |events|
        client.images.generate(prompt: "a cat", model: "gpt-image-1")

        expect(events.first).to include(
          provider: "openai",
          model: "gpt-image-1",
          input_tokens: 10,
          image_input_tokens: 15,
          output_tokens: 0,
          usage_source: :sdk_response
        )
      end
    end
  end

  describe "audio.transcriptions.create" do
    it "splits audio tokens out of input bucket on real SDK transcription" do
      stub_sdk_json(:post, "https://api.openai.com/v1/audio/transcriptions",
                    provider: :openai, fixture: "transcription_create.json")

      capture_sdk_events do |events|
        client.audio.transcriptions.create(file: audio_io, model: "gpt-4o-transcribe")

        expect(events.first).to include(
          provider: "openai",
          model: "gpt-4o-transcribe",
          input_tokens: 4,
          audio_input_tokens: 8,
          output_tokens: 3,
          usage_source: :sdk_response
        )
      end
    end
  end

  describe "audio.translations.create" do
    it "records translation through the transcription recorder" do
      stub_sdk_json(:post, "https://api.openai.com/v1/audio/translations",
                    provider: :openai, fixture: "transcription_create.json")

      capture_sdk_events do |events|
        client.audio.translations.create(file: audio_io, model: "whisper-1")

        expect(events.first).to include(provider: "openai", model: "whisper-1", usage_source: :sdk_response)
      end
    end
  end

  describe "audio.speech.create" do
    it "records speech character count from the request input" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/audio/speech")
             .to_return(status: 200, body: "binary-audio", headers: { "Content-Type" => "audio/mpeg" })

      capture_sdk_events do |events|
        client.audio.speech.create(model: "gpt-4o-mini-tts", voice: "alloy", input: "hello world")

        expect(events.first).to include(
          provider: "openai",
          model: "gpt-4o-mini-tts",
          input_tokens: 0,
          output_tokens: 0
        )
      end
    end
  end

  describe "moderations.create" do
    it "records moderation as a zero-token event from real SDK response" do
      stub_sdk_json(:post, "https://api.openai.com/v1/moderations",
                    provider: :openai, fixture: "moderations_create.json")

      capture_sdk_events do |events|
        client.moderations.create(input: "hello")

        expect(events.first).to include(
          provider: "openai",
          model: "omni-moderation-latest",
          input_tokens: 0,
          output_tokens: 0,
          usage_source: :sdk_response,
          provider_response_id: "modr_abc"
        )
      end
    end
  end
end
