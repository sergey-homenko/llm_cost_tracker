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
      config.gemini_api_key = "test-gemini"
    end
  end

  def ruby_llm_2?
    Gem::Version.new(RubyLLM::VERSION) >= Gem::Version.new("2.0.0")
  end

  def stub_openai_chat(id:, usage: nil)
    json = { "Content-Type" => "application/json" }
    completion = {
      id: id, object: "chat.completion", model: "gpt-4o",
      choices: [{ index: 0, message: { role: "assistant", content: "hi" }, finish_reason: "stop" }],
      usage: usage
    }.compact
    response = {
      id: id, object: "response", status: "completed", model: "gpt-4o",
      output: [{ type: "message", id: "msg_#{id}", status: "completed", role: "assistant",
                 content: [{ type: "output_text", text: "hi", annotations: [] }] }],
      usage: usage && responses_usage(usage)
    }.compact
    WebMock.stub_request(:post, "https://api.openai.com/v1/chat/completions")
           .to_return(status: 200, body: completion.to_json, headers: json)
    WebMock.stub_request(:post, "https://api.openai.com/v1/responses")
           .to_return(status: 200, body: response.to_json, headers: json)
  end

  def responses_usage(usage)
    {
      input_tokens: usage[:prompt_tokens],
      output_tokens: usage[:completion_tokens],
      total_tokens: usage[:total_tokens],
      input_tokens_details: { cached_tokens: usage.dig(:prompt_tokens_details, :cached_tokens).to_i },
      output_tokens_details: { reasoning_tokens: usage.dig(:completion_tokens_details, :reasoning_tokens).to_i }
    }
  end

  describe "chat" do
    it "records token usage with cache_read and reasoning splits for an OpenAI chat completion" do
      stub_openai_chat(
        id: "chatcmpl_x",
        usage: { prompt_tokens: 100, completion_tokens: 30, total_tokens: 130,
                 prompt_tokens_details: { cached_tokens: 25 },
                 completion_tokens_details: { reasoning_tokens: 8 } }
      )

      capture_sdk_events do |events|
        RubyLLM.chat(model: "gpt-4o").ask("hi")
        expect(events.first).to include(
          provider: "openai", model: "gpt-4o",
          input_tokens: 75, output_tokens: 30,
          cache_read_input_tokens: 25, hidden_output_tokens: 8,
          stream: false, usage_source: "sdk_response"
        )
      end
    end

    it "drops the event when the chat response carries no usage hash" do
      stub_openai_chat(id: "chatcmpl_y")

      capture_sdk_events do |events|
        RubyLLM.chat(model: "gpt-4o").ask("hi")
        expect(events).to be_empty
      end
    end

    it "captures a streamed Anthropic chat whose raw body is the SSE text rather than a parsed JSON hash" do
      sse = <<~SSE
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_stream","type":"message","role":"assistant","model":"claude-haiku-4-5","content":[],"usage":{"input_tokens":11,"output_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":9}}

        event: message_stop
        data: {"type":"message_stop"}
      SSE
      WebMock.stub_request(:post, "https://api.anthropic.com/v1/messages").to_return(
        status: 200, body: sse, headers: { "Content-Type" => "text/event-stream" }
      )

      capture_sdk_events do |events|
        RubyLLM.chat(model: "claude-haiku-4-5", provider: :anthropic, assume_model_exists: true).ask("hi") { |_chunk| }
        expect(events.first).to include(
          provider: "anthropic", stream: true, usage_source: "sdk_response",
          input_tokens: 11, output_tokens: 9
        )
      end
    end

    it "captures a streamed Gemini chat whose raw body is the SSE text rather than a parsed JSON hash" do
      sse = <<~SSE
        data: {"candidates":[{"content":{"parts":[{"text":"hi"}],"role":"model"},"finishReason":"STOP","index":0}],"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":1,"totalTokenCount":24,"promptTokensDetails":[{"modality":"TEXT","tokenCount":5}],"thoughtsTokenCount":18,"serviceTier":"standard"},"modelVersion":"gemini-2.5-flash","responseId":"resp_stream"}

      SSE
      WebMock.stub_request(:post, %r{generativelanguage\.googleapis\.com/.+:streamGenerateContent}).to_return(
        status: 200, body: sse, headers: { "Content-Type" => "text/event-stream" }
      )

      capture_sdk_events do |events|
        RubyLLM.chat(model: "gemini-2.5-flash", provider: :gemini, assume_model_exists: true).ask("hi") { |_chunk| }
        expect(events.first).to include(
          provider: "gemini", stream: true, usage_source: "sdk_response",
          input_tokens: 5, output_tokens: 19, hidden_output_tokens: 18
        )
      end
    end

    it "captures Anthropic batch service tier as pricing_mode :batch" do
      WebMock.stub_request(:post, "https://api.anthropic.com/v1/messages").to_return(
        status: 200,
        body: {
          id: "msg_b", type: "message", role: "assistant", model: "claude-sonnet-4-5",
          content: [{ type: "text", text: "hi" }], stop_reason: "end_turn",
          usage: { input_tokens: 10, output_tokens: 5, service_tier: "batch" }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        RubyLLM.chat(model: "claude-sonnet-4-5").ask("hi")
        expect(events.first).to include(provider: "anthropic", pricing_mode: "batch")
      end
    end

    it "splits Anthropic ephemeral 1h cache writes from the 5m bucket so 1h rates apply at 2x base instead of 1.25x" do
      WebMock.stub_request(:post, "https://api.anthropic.com/v1/messages").to_return(
        status: 200,
        body: {
          id: "msg_c", type: "message", role: "assistant", model: "claude-sonnet-4-5",
          content: [{ type: "text", text: "hi" }], stop_reason: "end_turn",
          usage: {
            input_tokens: 10, output_tokens: 5,
            cache_creation: { ephemeral_5m_input_tokens: 100, ephemeral_1h_input_tokens: 200 }
          }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        RubyLLM.chat(model: "claude-sonnet-4-5").ask("hi")
        expect(events.first).to include(
          cache_write_input_tokens: 100,
          cache_write_extended_input_tokens: 200
        )
      end
    end

    it "records the raw-body response id so each ledger row carries the upstream id for invoice cross-reference" do
      stub_openai_chat(id: "chatcmpl_with_id", usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 })

      capture_sdk_events do |events|
        RubyLLM.chat(model: "gpt-4o").ask("hi")
        expect(events.first[:provider_response_id]).to eq("chatcmpl_with_id")
      end
    end

    it "preserves Anthropic priority service tier as :priority so committed pricing isn't billed at standard rates" do
      WebMock.stub_request(:post, "https://api.anthropic.com/v1/messages").to_return(
        status: 200,
        body: {
          id: "msg_p", type: "message", role: "assistant", model: "claude-sonnet-4-5",
          content: [{ type: "text", text: "hi" }], stop_reason: "end_turn",
          usage: { input_tokens: 10, output_tokens: 5, service_tier: "priority" }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        RubyLLM.chat(model: "claude-sonnet-4-5").ask("hi")
        expect(events.first).to include(provider: "anthropic", pricing_mode: "priority")
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
          input_tokens: 7, output_tokens: 0, usage_source: "sdk_response"
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

    it "records a multi-image generation once, from the first image, as RubyLLM 2.x bills it" do
      skip "paint(count:) returns several images only on RubyLLM 2.x" unless ruby_llm_2?

      WebMock.stub_request(:post, "https://api.openai.com/v1/images/generations").to_return(
        status: 200,
        body: {
          created: 1, data: [{ url: "https://example.com/a.png" }, { url: "https://example.com/b.png" }],
          usage: { input_tokens: 50, output_tokens: 200,
                   input_tokens_details: { image_tokens: 30 },
                   output_tokens_details: { image_tokens: 160 } }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        RubyLLM.paint("a cat", model: "gpt-image-1", count: 2)
        expect(events.size).to eq(1)
        expect(events.first).to include(
          provider: "openai", model: "gpt-image-1",
          input_tokens: 20, image_input_tokens: 30,
          output_tokens: 40, image_output_tokens: 160
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

  describe ".image_usage" do
    it "returns an empty usage hash when the image carries neither usage nor raw usage" do
      expect(described_class.image_usage(Object.new)).to eq({})
      expect(described_class.image_usage(nil)).to eq({})
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
