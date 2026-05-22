# frozen_string_literal: true

require "spec_helper"
require "ruby_llm"
require "tempfile"

RSpec.describe LlmCostTracker::Integrations::RubyLlm do
  before do
    configure_sdk_integration(:ruby_llm)
    RubyLLM.configure do |config|
      config.openai_api_key = "test-openai"
      config.anthropic_api_key = "test-anthropic"
    end
  end

  describe "chat" do
    it "records token usage with cache_read and reasoning splits for an OpenAI chat completion" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
        status: 200,
        body: {
          id: "chatcmpl_x", object: "chat.completion", model: "gpt-4o",
          choices: [{ index: 0, message: { role: "assistant", content: "hi" }, finish_reason: "stop" }],
          usage: { prompt_tokens: 100, completion_tokens: 30, total_tokens: 130,
                   prompt_tokens_details: { cached_tokens: 25 },
                   completion_tokens_details: { reasoning_tokens: 8 } }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        RubyLLM.chat(model: "gpt-4o").ask("hi")
        expect(events.first).to include(
          provider: "openai", model: "gpt-4o",
          input_tokens: 75, output_tokens: 30,
          cache_read_input_tokens: 25, hidden_output_tokens: 8,
          stream: false, usage_source: :sdk_response
        )
      end
    end

    it "drops the event when the chat response carries no usage hash" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
        status: 200,
        body: {
          id: "chatcmpl_y", object: "chat.completion", model: "gpt-4o",
          choices: [{ index: 0, message: { role: "assistant", content: "hi" }, finish_reason: "stop" }]
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        RubyLLM.chat(model: "gpt-4o").ask("hi")
        expect(events).to be_empty
      end
    end

    it "captures Anthropic batch service tier as pricing_mode :batch" do
      WebMock.stub_request(:post, "https://api.anthropic.com/v1/messages").to_return(
        status: 200,
        body: {
          id: "msg_b", type: "message", role: "assistant", model: "claude-sonnet-4-5",
          content: [{ type: "text", text: "hi" }], stop_reason: "end_turn",
          service_tier: "batch",
          usage: { input_tokens: 10, output_tokens: 5 }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        RubyLLM.chat(model: "claude-sonnet-4-5").ask("hi")
        expect(events.first).to include(provider: "anthropic", pricing_mode: :batch)
      end
    end

    it "drops Anthropic priority service tier (committed throughput, not a surcharge) to nil pricing_mode" do
      WebMock.stub_request(:post, "https://api.anthropic.com/v1/messages").to_return(
        status: 200,
        body: {
          id: "msg_p", type: "message", role: "assistant", model: "claude-sonnet-4-5",
          content: [{ type: "text", text: "hi" }], stop_reason: "end_turn",
          service_tier: "priority",
          usage: { input_tokens: 10, output_tokens: 5 }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        RubyLLM.chat(model: "claude-sonnet-4-5").ask("hi")
        expect(events.first).to include(provider: "anthropic", pricing_mode: nil)
      end
    end
  end

  describe "embed" do
    it "records embedding token usage for an OpenAI embedding call" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/embeddings").to_return(
        status: 200,
        body: {
          object: "list", model: "text-embedding-3-small",
          data: [{ embedding: [0.1] }],
          usage: { prompt_tokens: 7, total_tokens: 7 }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        RubyLLM.embed("hi", model: "text-embedding-3-small")
        expect(events.first).to include(
          provider: "openai", model: "text-embedding-3-small",
          input_tokens: 7, output_tokens: 0, usage_source: :sdk_response
        )
      end
    end
  end

  describe "paint" do
    it "splits image input tokens out of text input for gpt-image-1" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/images/generations").to_return(
        status: 200,
        body: {
          created: 1, data: [{ url: "https://example.com/a.png" }],
          usage: { input_tokens: 50, output_tokens: 100,
                   input_tokens_details: { image_tokens: 30 },
                   output_tokens_details: { image_tokens: 80 } }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        RubyLLM.paint("a cat", model: "gpt-image-1")
        expect(events.first).to include(
          provider: "openai", model: "gpt-image-1",
          input_tokens: 20, image_input_tokens: 30,
          output_tokens: 20, image_output_tokens: 80
        )
      end
    end

    it "records a zero-token event when the image response has no usage hash" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/images/generations").to_return(
        status: 200,
        body: { created: 1, data: [{ url: "https://example.com/a.png" }] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        RubyLLM.paint("a cat", model: "gpt-image-1")
        expect(events.first).to include(
          provider: "openai", model: "gpt-image-1",
          input_tokens: 0, output_tokens: 0,
          image_input_tokens: 0, image_output_tokens: 0
        )
      end
    end
  end

  describe "transcribe" do
    it "records transcription token usage from a real OpenAI response" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/audio/transcriptions").to_return(
        status: 200,
        body: { text: "hi", usage: { type: "tokens", input_tokens: 12, output_tokens: 3 } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
      audio_file = Tempfile.new(["clip", ".wav"])
      audio_file.write("RIFF")
      audio_file.close

      capture_sdk_events do |events|
        RubyLLM.transcribe(audio_file.path, model: "whisper-1", language: "en")
        expect(events.first).to include(
          provider: "openai", model: "whisper-1",
          input_tokens: 12, output_tokens: 3
        )
      end
    ensure
      audio_file.unlink
    end
  end

  describe "moderate" do
    it "records moderation as a zero-token event" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/moderations").to_return(
        status: 200,
        body: { id: "modr_x", model: "omni-moderation-latest",
                results: [{ flagged: false, categories: {}, category_scores: {} }] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        RubyLLM.moderate("hi", model: "omni-moderation-latest")
        expect(events.first).to include(
          provider: "openai", model: "omni-moderation-latest",
          input_tokens: 0, output_tokens: 0
        )
      end
    end
  end
end
