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
    before do
      WebMock.stub_request(:post, "https://api.openai.com/v1/audio/speech")
             .to_return(status: 200, body: "binary-audio", headers: { "Content-Type" => "audio/mpeg" })
    end

    it "emits a text_to_speech_character line item priced by input length for tts-1" do
      capture_sdk_events do |events|
        client.audio.speech.create(model: "tts-1", voice: "alloy", input: "hello world")

        line_item = events.first[:line_items].find { |item| item[:kind] == :text_to_speech_character }
        expect(line_item[:quantity].to_i).to eq("hello world".length)
      end
    end

    it "does not emit a line item for non-character-billed TTS models like gpt-4o-mini-tts" do
      capture_sdk_events do |events|
        client.audio.speech.create(model: "gpt-4o-mini-tts", voice: "alloy", input: "hello world")

        kinds = events.first[:line_items].map { |item| item[:kind] }
        expect(kinds).not_to include(:text_to_speech_character)
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

  describe "chat.completions streaming" do
    let(:chat_sse_body) do
      <<~SSE
        data: {"id":"chatcmpl_s","object":"chat.completion.chunk","model":"gpt-4o","choices":[{"index":0,"delta":{"content":"hi"}}]}

        data: {"id":"chatcmpl_s","object":"chat.completion.chunk","model":"gpt-4o","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}

        data: [DONE]

      SSE
    end

    it "records token usage from chat.completions.stream" do
      stub_sdk_sse(:post, "https://api.openai.com/v1/chat/completions", body: chat_sse_body)

      capture_sdk_events do |events|
        stream = client.chat.completions.stream(
          model: "gpt-4o", messages: [{ role: "user", content: "hi" }]
        )
        stream.each { |_| }

        expect(events.first).to include(
          provider: "openai", model: "gpt-4o", stream: true,
          input_tokens: 10, output_tokens: 5,
          usage_source: :stream_final, provider_response_id: "chatcmpl_s"
        )
      end
    end

    it "records token usage from chat.completions.stream_raw" do
      stub_sdk_sse(:post, "https://api.openai.com/v1/chat/completions", body: chat_sse_body)

      capture_sdk_events do |events|
        stream = client.chat.completions.stream_raw(
          model: "gpt-4o", messages: [{ role: "user", content: "hi" }]
        )
        stream.each { |_| }

        expect(events.first).to include(
          provider: "openai", stream: true, input_tokens: 10, output_tokens: 5
        )
      end
    end
  end

  describe "responses streaming" do
    let(:responses_sse_body) do
      <<~SSE
        event: response.created
        data: {"type":"response.created","response":{"id":"resp_stream","model":"gpt-4o"}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_stream","model":"gpt-4o","usage":{"input_tokens":20,"output_tokens":7,"total_tokens":27}}}

      SSE
    end

    it "records token usage from responses.stream" do
      stub_sdk_sse(:post, "https://api.openai.com/v1/responses", body: responses_sse_body)

      capture_sdk_events do |events|
        stream = client.responses.stream(model: "gpt-4o", input: "hi")
        stream.each { |_| }

        expect(events.first).to include(
          provider: "openai", model: "gpt-4o", stream: true,
          input_tokens: 20, output_tokens: 7,
          usage_source: :stream_final, provider_response_id: "resp_stream"
        )
      end
    end

    it "records token usage from responses.stream_raw" do
      stub_sdk_sse(:post, "https://api.openai.com/v1/responses", body: responses_sse_body)

      capture_sdk_events do |events|
        stream = client.responses.stream_raw(model: "gpt-4o", input: "hi")
        stream.each { |_| }

        expect(events.first).to include(
          provider: "openai", model: "gpt-4o", stream: true,
          input_tokens: 20, output_tokens: 7,
          provider_response_id: "resp_stream"
        )
      end
    end

    it "records token usage from responses.retrieve_streaming, falling back to the URL response id when SSE chunks omit it" do
      idless_sse = <<~SSE
        event: response.completed
        data: {"type":"response.completed","response":{"model":"gpt-4o","usage":{"input_tokens":20,"output_tokens":7,"total_tokens":27}}}

      SSE
      stub_sdk_sse(:get, "https://api.openai.com/v1/responses/resp_retrieve", body: idless_sse)

      capture_sdk_events do |events|
        stream = client.responses.retrieve_streaming("resp_retrieve")
        stream.each { |_| }

        expect(events.first).to include(
          provider: "openai", stream: true,
          input_tokens: 20, output_tokens: 7,
          provider_response_id: "resp_retrieve"
        )
      end
    end
  end

  describe "responses.create extras" do
    it "captures audio input/output tokens split from text input/output" do
      stub_sdk_json(:post, "https://api.openai.com/v1/responses",
                    provider: :openai, fixture: "responses_with_audio.json")

      capture_sdk_events do |events|
        client.responses.create(model: "gpt-4o-audio-preview", input: "hi")
        expect(events.first).to include(
          audio_input_tokens: 15,
          audio_output_tokens: 25,
          input_tokens: 15,
          output_tokens: 15
        )
      end
    end

    it "captures the priority service tier as a pricing mode" do
      stub_sdk_json(:post, "https://api.openai.com/v1/responses",
                    provider: :openai, fixture: "responses_with_service_tier.json")

      capture_sdk_events do |events|
        client.responses.create(model: "gpt-4o", input: "hi")
        expect(events.first[:pricing_mode]).to eq(:priority)
      end
    end

    it "records hosted-tool calls as service line items, deduplicating containers by id" do
      stub_sdk_json(:post, "https://api.openai.com/v1/responses",
                    provider: :openai, fixture: "responses_with_tool_output.json")

      capture_sdk_events do |events|
        client.responses.create(model: "gpt-4o", input: "hi")
        kinds = events.first[:line_items].reject { |item| item[:unit] == :token }.map { |item| item[:kind] }
        expect(kinds).to contain_exactly(:web_search_request, :file_search_call, :container_session)
      end
    end
  end

  describe "Azure OpenAI base_url" do
    let(:azure_client) do
      OpenAI::Client.new(api_key: "test-key", base_url: "https://my-resource.openai.azure.com/openai/v1/")
    end

    it "tags responses.create as azure_openai when the SDK client targets *.openai.azure.com" do
      stub_sdk_json(:post, "https://my-resource.openai.azure.com/openai/v1/responses",
                    provider: :openai, fixture: "responses_create.json")

      capture_sdk_events do |events|
        azure_client.responses.create(model: "gpt-4o", input: "hi")
        expect(events.first).to include(provider: "azure_openai")
      end
    end

    it "tags chat.completions.create as azure_openai under the same base_url" do
      stub_sdk_json(:post, "https://my-resource.openai.azure.com/openai/v1/chat/completions",
                    provider: :openai, fixture: "chat_completions_create.json")

      capture_sdk_events do |events|
        azure_client.chat.completions.create(model: "gpt-4o", messages: [{ role: "user", content: "hi" }])
        expect(events.first).to include(provider: "azure_openai")
      end
    end

    it "tags embeddings.create as azure_openai under the same base_url" do
      stub_sdk_json(:post, "https://my-resource.openai.azure.com/openai/v1/embeddings",
                    provider: :openai, fixture: "embeddings_create.json")

      capture_sdk_events do |events|
        azure_client.embeddings.create(model: "text-embedding-3-large", input: "hi")
        expect(events.first).to include(provider: "azure_openai")
      end
    end

    it "also recognises the services.ai.azure.com host as Azure" do
      stub_sdk_json(:post, "https://my-resource.services.ai.azure.com/openai/v1/responses",
                    provider: :openai, fixture: "responses_create.json")
      client = OpenAI::Client.new(api_key: "test-key",
                                  base_url: "https://my-resource.services.ai.azure.com/openai/v1/")

      capture_sdk_events do |events|
        client.responses.create(model: "gpt-4o", input: "hi")
        expect(events.first).to include(provider: "azure_openai")
      end
    end

    it "keeps the openai provider tag when the base_url is the public api.openai.com" do
      stub_sdk_json(:post, "https://api.openai.com/v1/responses",
                    provider: :openai, fixture: "responses_create.json")

      capture_sdk_events do |events|
        client.responses.create(model: "gpt-4o", input: "hi")
        expect(events.first).to include(provider: "openai")
      end
    end
  end

  describe "data residency pricing" do
    let(:dr_client) { OpenAI::Client.new(api_key: "test-key", base_url: "https://us.api.openai.com/v1/") }

    def stub_responses_for(model)
      WebMock.stub_request(:post, "https://us.api.openai.com/v1/responses").to_return(
        status: 200,
        body: { id: "resp_dr", object: "response", model: model, status: "completed",
                created_at: 1, output: [],
                usage: { input_tokens: 10, output_tokens: 5, total_tokens: 15 } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
    end

    it "applies data_residency pricing mode for an uplifted model on us.api.openai.com" do
      stub_responses_for("gpt-5.4-mini")

      capture_sdk_events do |events|
        dr_client.responses.create(model: "gpt-5.4-mini", input: "hi")
        expect(events.first).to include(provider: "openai", pricing_mode: :data_residency)
      end
    end

    it "does not apply data_residency for non-uplifted models on the same host" do
      stub_responses_for("gpt-4o")

      capture_sdk_events do |events|
        dr_client.responses.create(model: "gpt-4o", input: "hi")
        expect(events.first[:pricing_mode]).to be_nil
      end
    end
  end

  describe "gpt-image model splits" do
    it "routes Responses.create output to image_output_tokens when usage omits the output detail split" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/responses").to_return(
        status: 200,
        body: {
          id: "resp_image", object: "response", model: "gpt-image-1", status: "completed",
          created_at: 1, output: [],
          usage: { input_tokens: 0, output_tokens: 200, total_tokens: 200 }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        client.responses.create(model: "gpt-image-1", input: "draw")
        expect(events.first).to include(provider: "openai", model: "gpt-image-1",
                                        output_tokens: 0, image_output_tokens: 200)
      end
    end

    it "subtracts cached input from text input for gpt-image-1" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/images/generations").to_return(
        status: 200,
        body: {
          created: 1, data: [],
          usage: {
            input_tokens: 50, output_tokens: 0, total_tokens: 50,
            input_tokens_details: { cached_tokens: 20, image_tokens: 15, text_tokens: 15 }
          }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        client.images.generate(prompt: "a cat", model: "gpt-image-1")
        expect(events.first).to include(
          input_tokens: 15, cache_read_input_tokens: 20, image_input_tokens: 15,
          output_tokens: 0, image_output_tokens: 0
        )
      end
    end
  end
end
