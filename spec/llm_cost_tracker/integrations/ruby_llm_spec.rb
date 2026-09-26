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
      config.deepseek_api_key = "test-deepseek"
    end
  end

  def stub_openai_chat(id:, usage: nil, model: "gpt-4o", host: "api.openai.com")
    json = { "Content-Type" => "application/json" }
    completion = {
      id: id, object: "chat.completion", model: model,
      choices: [{ index: 0, message: { role: "assistant", content: "hi" }, finish_reason: "stop" }],
      usage: usage
    }.compact
    response = {
      id: id, object: "response", status: "completed", model: model,
      output: [{ type: "message", id: "msg_#{id}", status: "completed", role: "assistant",
                 content: [{ type: "output_text", text: "hi", annotations: [] }] }],
      usage: usage && responses_usage(usage)
    }.compact
    WebMock.stub_request(:post, "https://#{host}/v1/chat/completions")
           .to_return(status: 200, body: completion.to_json, headers: json)
    WebMock.stub_request(:post, "https://#{host}/v1/responses")
           .to_return(status: 200, body: response.to_json, headers: json)
  end

  def anthropic_message(id:, model:, usage:, stop_reason: "end_turn")
    { id: id, type: "message", role: "assistant", model: model,
      content: [{ type: "text", text: "hi" }], stop_reason: stop_reason, usage: usage }
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

    it "prices Anthropic US inference and fast mode from usage.inference_geo and usage.speed" do
      {
        "claude-sonnet-4-6" => [{ inference_geo: "us" }, "data_residency", "0.0495"],
        "claude-opus-5-5" => [{ speed: "fast" }, "fast", "0.12"]
      }.each do |model, (usage, mode, total)|
        WebMock.stub_request(:post, "https://api.anthropic.com/v1/messages").to_return(
          status: 200,
          body: anthropic_message(id: "msg_#{mode}", model: model,
                                  usage: { input_tokens: 10_000, output_tokens: 1_000 }.merge(usage)).to_json,
          headers: { "Content-Type" => "application/json" }
        )

        capture_sdk_events do |events|
          RubyLLM.chat(model: model, provider: :anthropic, assume_model_exists: true).ask("hi")
          expect(events.first).to include(pricing_mode: mode)
          expect(events.first.dig(:cost, :total)).to eq(total)
        end
      end
    end

    it "prices an OpenAI chat sent to a regional host at the data-residency rate" do
      stub_openai_chat(id: "chatcmpl_eu", model: "gpt-5.4", host: "eu.api.openai.com",
                       usage: { prompt_tokens: 10_000, completion_tokens: 1_000, total_tokens: 11_000 })

      capture_sdk_events do |events|
        RubyLLM.context { |config| config.openai_api_base = "https://eu.api.openai.com/v1" }
               .chat(model: "gpt-5.4", provider: :openai, assume_model_exists: true).ask("hi")
        expect(events.first).to include(pricing_mode: "data_residency")
        expect(events.first.dig(:cost, :total)).to eq("0.044")
      end
    end

    it "keeps the cache writes of earlier pause_turn segments that RubyLLM merges into one message" do
      skip "RubyLLM continues pause_turn automatically only on 2.x" if RubyLLM::VERSION.start_with?("1.")

      segments = [
        anthropic_message(id: "msg_seg1", model: "claude-sonnet-4-6", stop_reason: "pause_turn",
                          usage: { input_tokens: 20, output_tokens: 200, cache_creation_input_tokens: 8000,
                                   cache_creation: { ephemeral_5m_input_tokens: 8000, ephemeral_1h_input_tokens: 0 } }),
        anthropic_message(id: "msg_seg2", model: "claude-sonnet-4-6",
                          usage: { input_tokens: 30, output_tokens: 400, cache_read_input_tokens: 8000,
                                   cache_creation_input_tokens: 1500,
                                   cache_creation: { ephemeral_5m_input_tokens: 1500, ephemeral_1h_input_tokens: 0 } })
      ]
      WebMock.stub_request(:post, "https://api.anthropic.com/v1/messages").to_return(
        *segments.map { |body| { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } } }
      )

      capture_sdk_events do |events|
        RubyLLM.chat(model: "claude-sonnet-4-6", provider: :anthropic, assume_model_exists: true).ask("research")
        expect(events.first).to include(cache_write_input_tokens: 9500, cache_write_extended_input_tokens: 0)
        expect(events.first.dig(:cost, :total)).to eq("0.047175")
      end
    end

    it "prices Gemini audio prompt tokens and url_context tool-use prompt tokens from the raw usageMetadata" do
      WebMock.stub_request(:post, %r{generativelanguage\.googleapis\.com/v1beta/models/gemini-2\.5-flash:generateContent})
             .to_return(
               status: 200,
               body: {
                 candidates: [{ content: { role: "model", parts: [{ text: "hi" }] }, finishReason: "STOP" }],
                 usageMetadata: { promptTokenCount: 19_210, candidatesTokenCount: 500, toolUsePromptTokenCount: 8000,
                                  promptTokensDetails: [{ modality: "TEXT", tokenCount: 10 },
                                                        { modality: "AUDIO", tokenCount: 19_200 }] },
                 modelVersion: "gemini-2.5-flash"
               }.to_json,
               headers: { "Content-Type" => "application/json" }
             )

      capture_sdk_events do |events|
        RubyLLM.chat(model: "gemini-2.5-flash", provider: :gemini, assume_model_exists: true).ask("hi")
        expect(events.first).to include(input_tokens: 8010, audio_input_tokens: 19_200, output_tokens: 500)
        expect(events.first.dig(:cost, :total)).to eq("0.022853")
      end
    end

    it "records Anthropic web search and Gemini grounding fees from the raw body, and none for other providers" do
      WebMock.stub_request(:post, "https://api.anthropic.com/v1/messages").to_return(
        status: 200,
        body: anthropic_message(id: "msg_ws", model: "claude-sonnet-4-5",
                                usage: { input_tokens: 5000, output_tokens: 800,
                                         server_tool_use: { web_search_requests: 2 } }).to_json,
        headers: { "Content-Type" => "application/json" }
      )
      WebMock.stub_request(:post, %r{generativelanguage\.googleapis\.com/v1beta/models/gemini-3\.8-flash:generateContent})
             .to_return(
               status: 200,
               body: {
                 candidates: [{ content: { role: "model", parts: [{ text: "hi" }] }, finishReason: "STOP",
                                groundingMetadata: { webSearchQueries: %w[q1 q2] } }],
                 usageMetadata: { promptTokenCount: 1000, candidatesTokenCount: 500, thoughtsTokenCount: 500 },
                 modelVersion: "gemini-3.8-flash"
               }.to_json,
               headers: { "Content-Type" => "application/json" }
             )
      stub_openai_chat(id: "chatcmpl_ds", model: "deepseek-chat", host: "api.deepseek.com",
                       usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 })

      capture_sdk_events do |events|
        RubyLLM.chat(model: "claude-sonnet-4-5", provider: :anthropic, assume_model_exists: true).ask("news?")
        RubyLLM.chat(model: "gemini-3.8-flash", provider: :gemini, assume_model_exists: true).ask("news?")
        RubyLLM.context { |config| config.deepseek_api_base = "https://api.deepseek.com/v1" }
               .chat(model: "deepseek-chat", provider: :deepseek, assume_model_exists: true).ask("news?")
        fees = events.map { |event| event[:line_items].find { |item| item[:unit] != "token" }&.values_at(:kind, :quantity) }
        expect(fees).to eq([%w[web_search_request 2.0], %w[grounding_request 2.0], nil])
        expect(events.first(2).map { |event| event.dig(:cost, :total) }).to eq(%w[0.047 0.0325])
      end
    end

    it "records an OpenAI Responses web_search_call fee" do
      skip "RubyLLM 1.x chats through Chat Completions only" if RubyLLM::VERSION.start_with?("1.")

      WebMock.stub_request(:post, "https://api.openai.com/v1/responses").to_return(
        status: 200,
        body: {
          id: "resp_ws", object: "response", status: "completed", model: "gpt-5.4",
          output: [{ type: "web_search_call", id: "ws_1", status: "completed", action: { type: "search", query: "q" } },
                   { type: "message", id: "msg_ws", status: "completed", role: "assistant",
                     content: [{ type: "output_text", text: "hi", annotations: [] }] }],
          usage: { input_tokens: 3000, output_tokens: 500, total_tokens: 3500 }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        RubyLLM.chat(model: "gpt-5.4", provider: :openai, assume_model_exists: true)
               .with_provider_tools(:web_search).ask("news?")
        expect(events.first[:line_items].map { |item| item[:kind] }).to include("web_search_request")
        expect(events.first.dig(:cost, :total)).to eq("0.025")
      end
    end
  end

  describe "budget preflight" do
    it "blocks a chat before sending it when the estimate of its prompt alone crosses budgets.per_call" do
      allow(LlmCostTracker.configuration.budgets).to receive_messages(exceeded_behavior: :block_requests, per_call: 0.2)
      stub_openai_chat(id: "chatcmpl_big", usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 })

      expect { RubyLLM.chat(model: "gpt-4o").ask("x" * 400_000) }.to raise_error(
        an_instance_of(LlmCostTracker::BudgetExceededError).and(having_attributes(stage: :pre_send, budget_type: :per_call))
      )
      expect(WebMock).not_to have_requested(:post, /api\.openai\.com/)
    end

    it "estimates the text of a message with an attachment, which RubyLLM 1.x returns as a RubyLLM::Content" do
      allow(LlmCostTracker.configuration.budgets).to receive_messages(exceeded_behavior: :block_requests, per_call: 0.2)
      stub_openai_chat(id: "chatcmpl_attached", usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 })
      image = Tempfile.new(["pic", ".png"], binmode: true)
      image.write("\x89PNG\r\n\x1a\n".b + ("\x00".b * 64))
      image.flush

      expect { RubyLLM.chat(model: "gpt-4o").ask("x" * 400_000, with: image.path) }.to raise_error(
        an_instance_of(LlmCostTracker::BudgetExceededError).and(having_attributes(stage: :pre_send, budget_type: :per_call))
      )
      expect(WebMock).not_to have_requested(:post, /api\.openai\.com/)
    ensure
      image&.close!
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
    it "prices Gemini native image output at the image rate and its text and thinking at the text rate" do
      skip "Gemini image models paint through generateContent only on RubyLLM 2.x" if RubyLLM::VERSION.start_with?("1.")

      model = "gemini-3.1-flash-image-preview"
      parts = [{ text: "Here is your fox." }, { inlineData: { mimeType: "image/png", data: "iVBORw0KGgo=" } }]
      WebMock.stub_request(:post, "https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent")
             .to_return(
               status: 200,
               body: {
                 candidates: [{ content: { role: "model", parts: parts }, finishReason: "STOP" }],
                 usageMetadata: { promptTokenCount: 12, candidatesTokenCount: 1145, thoughtsTokenCount: 180,
                                  candidatesTokensDetails: [{ modality: "TEXT", tokenCount: 25 },
                                                            { modality: "IMAGE", tokenCount: 1120 }] },
                 modelVersion: model
               }.to_json,
               headers: { "Content-Type" => "application/json" }
             )

      capture_sdk_events do |events|
        RubyLLM.paint("a watercolor fox", model: model, provider: :gemini, assume_model_exists: true)
        expect(events.first).to include(input_tokens: 12, output_tokens: 205, image_output_tokens: 1120)
        expect(events.first.dig(:cost, :total)).to eq("0.067821")
      end
    end

    it "prices gpt-image output as image output when the usage has no output_tokens_details" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/images/generations").to_return(
        status: 200,
        body: {
          created: 1, data: [{ b64_json: "iVBORw0KGgo=" }],
          usage: { total_tokens: 4210, input_tokens: 50, output_tokens: 4160,
                   input_tokens_details: { text_tokens: 50, image_tokens: 0 } }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        RubyLLM.paint("a fox", model: "gpt-image-1")
        expect(events.first).to include(input_tokens: 50, output_tokens: 0, image_output_tokens: 4160)
        expect(events.first.dig(:cost, :total)).to eq("0.16665")
      end
    end

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
      skip "paint(count:) returns several images only on RubyLLM 2.x" if RubyLLM::VERSION.start_with?("1.")

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

  describe "transcribe" do
    let(:audio_file) { Tempfile.new(["clip", ".wav"]) }

    after { audio_file.close! }

    it "records transcription token usage from a real OpenAI response" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/audio/transcriptions").to_return(
        status: 200,
        body: { text: "hi", usage: { type: "tokens", input_tokens: 12, output_tokens: 3 } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        RubyLLM.transcribe(audio_file.path, model: "whisper-1", language: "en")
        expect(events.first).to include(
          provider: "openai", model: "whisper-1",
          input_tokens: 12, output_tokens: 3
        )
      end
    end

    it "prices a duration-billed transcription by the started minute when RubyLLM reports no tokens" do
      skip "RubyLLM 1.x drops usage.seconds from the transcription" if RubyLLM::VERSION.start_with?("1.")

      WebMock.stub_request(:post, "https://api.openai.com/v1/audio/transcriptions").to_return(
        status: 200,
        body: { text: "hi", usage: { type: "duration", seconds: 600 } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        RubyLLM.transcribe(audio_file.path, model: "gpt-transcribe", provider: :openai, assume_model_exists: true)
        line = events.first[:line_items].find { |item| item[:kind] == "transcription_minute" }
        expect(line[:quantity].to_i).to eq(10)
        expect(events.first.dig(:cost, :total)).to eq("0.045")
      end
    end

    it "records a Gemini transcription once, although RubyLLM 1.x Gemini never calls Provider#transcribe" do
      url = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
      WebMock.stub_request(:post, url).to_return(
        status: 200,
        body: {
          candidates: [{ content: { role: "model", parts: [{ text: "hi" }] }, finishReason: "STOP" }],
          usageMetadata: { promptTokenCount: 40, candidatesTokenCount: 5, thoughtsTokenCount: 2 }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        RubyLLM.transcribe(audio_file.path, model: "gemini-2.5-flash", provider: :gemini, assume_model_exists: true)
        expect(events.size).to eq(1)
        expect(events.first).to include(provider: "gemini", model: "gemini-2.5-flash", input_tokens: 0,
                                        audio_input_tokens: 40, output_tokens: 7)
      end
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
