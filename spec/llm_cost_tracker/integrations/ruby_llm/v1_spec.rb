# frozen_string_literal: true

require "spec_helper"
require "ruby_llm"
require "tempfile"

RSpec.describe LlmCostTracker::Integrations::RubyLlm::V1, if: RubyLLM::VERSION.start_with?("1.") do
  before do
    configure_sdk_integration(:ruby_llm)
    RubyLLM.configure do |config|
      config.openai_api_key = "test-openai"
      config.anthropic_api_key = "test-anthropic"
      config.gemini_api_key = "test-gemini"
      config.deepseek_api_key = "test-deepseek"
      config.openrouter_api_key = "test-openrouter"
    end
  end

  def sse(*events) = events.map { |event| "data: #{event.to_json}\n\n" }.join

  def sse_response(body) = { status: 200, body: body, headers: { "Content-Type" => "text/event-stream" } }

  def override_prices(prices)
    LlmCostTrackerReset.call
    LlmCostTracker.configure do |config|
      config.pricing.unknown_model_behavior = :ignore
      config.instrument(:ruby_llm)
      config.pricing.overrides = prices
    end
  end

  def stub_openai_chat(id:, usage: nil, model: "gpt-4o", host: "api.openai.com", **extra)
    json = { "Content-Type" => "application/json" }
    completion = {
      id: id, object: "chat.completion", model: model,
      choices: [{ index: 0, message: { role: "assistant", content: "hi" }, finish_reason: "stop" }],
      usage: usage, **extra
    }.compact
    WebMock.stub_request(:post, "https://#{host}/v1/chat/completions")
           .to_return(status: 200, body: completion.to_json, headers: json)
  end

  def anthropic_message(id:, model:, usage:, stop_reason: "end_turn")
    { id: id, type: "message", role: "assistant", model: model,
      content: [{ type: "text", text: "hi" }], stop_reason: stop_reason, usage: usage }
  end

  def anthropic_stream(id:, usage:, delta_usage:, stop_reason: "end_turn")
    sse_response(sse(
      { type: "message_start", message: anthropic_message(id: id, model: "claude-sonnet-4-6", usage: usage)
                                          .merge(content: [], stop_reason: nil) },
      { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
      { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "hi" } },
      { type: "content_block_stop", index: 0 },
      { type: "message_delta", delta: { stop_reason: stop_reason }, usage: delta_usage },
      { type: "message_stop" }
    ))
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
          provider: "gemini", stream: true, usage_source: "sdk_response", provider_response_id: "resp_stream",
          input_tokens: 5, output_tokens: 19, hidden_output_tokens: 18
        )
      end
    end

    it "prices a streamed Anthropic chat from its events: 1-hour cache writes, US inference, response id" do
      usage = { input_tokens: 50, cache_creation_input_tokens: 20_000, cache_read_input_tokens: 0,
                cache_creation: { ephemeral_5m_input_tokens: 0, ephemeral_1h_input_tokens: 20_000 },
                output_tokens: 1, service_tier: "standard", inference_geo: "us" }
      WebMock.stub_request(:post, "https://api.anthropic.com/v1/messages")
             .to_return(anthropic_stream(id: "msg_s1h", usage: usage, delta_usage: { output_tokens: 300 }))

      capture_sdk_events do |events|
        RubyLLM.chat(model: "claude-sonnet-4-6", provider: :anthropic, assume_model_exists: true).ask("hi") { |_chunk| }
        expect(events.first).to include(cache_write_input_tokens: 0, cache_write_extended_input_tokens: 20_000,
                                        pricing_mode: "data_residency", provider_response_id: "msg_s1h", stream: true)
        expect(events.first.dig(:cost, :total)).to eq("0.137115")
      end
    end

    it "counts a streamed Anthropic chat's input from message_delta, whose cumulative count adds server tool results" do
      WebMock.stub_request(:post, "https://api.anthropic.com/v1/messages").to_return(anthropic_stream(
        id: "msg_sws", usage: { input_tokens: 2679, output_tokens: 3 },
        delta_usage: { input_tokens: 10_682, cache_creation_input_tokens: 0, cache_read_input_tokens: 0,
                       output_tokens: 510, server_tool_use: { web_search_requests: 1 } }
      ))

      capture_sdk_events do |events|
        RubyLLM.chat(model: "claude-sonnet-4-6", provider: :anthropic, assume_model_exists: true).ask("news?") { |_c| }
        expect(events.first).to include(input_tokens: 10_682, output_tokens: 510)
        expect(events.first.dig(:cost, :total)).to eq("0.049696")
      end
    end

    it "prices a streamed OpenAI chat at the service tier its final event reports" do
      usage = { prompt_tokens: 2000, completion_tokens: 500, total_tokens: 2500 }
      chunk = { id: "chatcmpl_flex", object: "chat.completion.chunk", model: "gpt-5-mini", service_tier: "flex" }
      WebMock.stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(sse_response(sse(
        chunk.merge(choices: [{ index: 0, delta: { role: "assistant", content: "hi" }, finish_reason: "stop" }]),
        chunk.merge(choices: [], usage: usage)
      )))

      capture_sdk_events do |events|
        RubyLLM.chat(model: "gpt-5-mini", provider: :openai, assume_model_exists: true).ask("hi") { |_chunk| }
        expect(events.first).to include(pricing_mode: "flex", input_tokens: 2000, output_tokens: 500, stream: true)
        expect(events.first.dig(:cost, :total)).to eq("0.00075")
      end
    end

    it "records OpenRouter's billed usage.cost, adding the upstream cost of a BYOK call, blocking and streamed" do
      usage = { prompt_tokens: 1000, completion_tokens: 200, total_tokens: 1200, cost: 0.0003, is_byok: true,
                cost_details: { upstream_inference_cost: 0.006 } }
      completion = { id: "gen-1", object: "chat.completion", model: "deepseek/deepseek-v3.2",
                     choices: [{ index: 0, message: { role: "assistant", content: "hi" }, finish_reason: "stop" }] }
      chunk = { id: "gen-2", object: "chat.completion.chunk", model: "deepseek/deepseek-v3.2" }
      WebMock.stub_request(:post, "https://openrouter.ai/api/v1/chat/completions").to_return(
        { status: 200, body: completion.merge(usage: usage).to_json, headers: { "Content-Type" => "application/json" } },
        sse_response(sse(chunk.merge(choices: [{ index: 0, delta: { content: "hi" }, finish_reason: "stop" }]),
                         chunk.merge(choices: [], usage: usage.merge(cost: 0.0056, is_byok: false))))
      )

      capture_sdk_events do |events|
        chat = -> { RubyLLM.chat(model: "deepseek/deepseek-v3.2", provider: :openrouter, assume_model_exists: true) }
        chat.call.ask("hi")
        chat.call.ask("hi") { |_chunk| }
        expect(events.map { |event| event[:line_items].find { |item| item[:kind] == "billed_request" }&.dig(:cost) })
          .to eq(%w[0.0063 0.0056])
        expect(events.map { |event| event.dig(:cost, :total) }).to eq(%w[0.0063 0.0056])
      end
    end

    it "counts Bedrock Converse inputTokens as the uncached input, which RubyLLM 1.x reduces by the cache tokens" do
      model = "anthropic.claude-sonnet-4-5-20250929-v1:0"
      rates = { "input" => 3.3, "output" => 16.5, "cache_read_input" => 0.33 }
      override_prices(%W[bedrock/#{model} bedrock/us.#{model}].index_with(rates))
      RubyLLM.configure do |config|
        config.bedrock_api_key = "AKIATEST"
        config.bedrock_secret_key = "test-secret"
        config.bedrock_region = "us-east-1"
      end
      WebMock.stub_request(:post, %r{\Ahttps://bedrock-runtime\.us-east-1\.amazonaws\.com/model/.+/converse\z}).to_return(
        status: 200,
        body: { output: { message: { role: "assistant", content: [{ text: "hi" }] } }, stopReason: "end_turn",
                usage: { inputTokens: 3000, cacheReadInputTokens: 2000, cacheWriteInputTokens: 0,
                         outputTokens: 400, totalTokens: 5400 } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        RubyLLM.chat(model: model, provider: :bedrock, assume_model_exists: true).ask("hi")
        expect(events.first).to include(input_tokens: 3000, cache_read_input_tokens: 2000, output_tokens: 400)
        expect(events.first.dig(:cost, :total)).to eq("0.01716")
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

    it "prices a Bedrock chat on a regional Claude inference profile at the regional rate" do
      LlmCostTrackerReset.call
      LlmCostTracker.configure do |config|
        config.pricing.overrides = { "anthropic/claude-sonnet-4-5" => { input: 3.0, output: 15.0, data_residency_input: 3.3,
                                                                        data_residency_output: 16.5 } }
        config.instrument(:ruby_llm)
      end
      bedrock = RubyLLM.context do |config|
        config.bedrock_api_key = "AKIDEXAMPLE"
        config.bedrock_secret_key = "secret"
        config.bedrock_region = "us-east-1"
      end
      body = { output: { message: { role: "assistant", content: [{ text: "hi" }] } }, stopReason: "end_turn",
               usage: { inputTokens: 1000, outputTokens: 500, totalTokens: 1500 } }
      WebMock.stub_request(:post, %r{\Ahttps://bedrock-runtime\.us-east-1\.amazonaws\.com/model/.+/converse\z})
             .to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })

      capture_sdk_events do |events|
        bedrock.chat(model: "us.anthropic.claude-sonnet-4-5-20250929-v1:0", provider: :bedrock,
                     assume_model_exists: true).ask("hi")
        expect(events.first).to include(provider: "bedrock", pricing_mode: "data_residency")
        expect(events.first.dig(:cost, :total)).to eq("0.01155")
      end
    end

    it "prices Bedrock 1-hour cache writes from cacheDetails" do
      RubyLLM.configure do |config|
        config.bedrock_api_key = "AKIATEST"
        config.bedrock_secret_key = "test-secret"
        config.bedrock_region = "us-east-1"
      end
      usage = { inputTokens: 3000, cacheWriteInputTokens: 4000, outputTokens: 800, totalTokens: 7800 }
      WebMock.stub_request(:post, %r{\Ahttps://bedrock-runtime\.us-east-1\.amazonaws\.com/model/.+/converse\z}).to_return(
        *[usage.merge(cacheDetails: [{ ttl: "1h", inputTokens: 3000 }, { ttl: "5m", inputTokens: 1000 }]), usage].map do |body|
          { status: 200, headers: { "Content-Type" => "application/json" },
            body: { output: { message: { role: "assistant", content: [{ text: "hi" }] } }, stopReason: "end_turn",
                    usage: body }.to_json }
        end
      )
      chat = -> { RubyLLM.chat(model: "us.anthropic.claude-sonnet-4-5-20250929-v1:0", provider: :bedrock, assume_model_exists: true) }

      capture_sdk_events do |events|
        chat.call.ask("hi")
        expect(events.last).to include(cache_write_input_tokens: 1000, cache_write_extended_input_tokens: 3000)
        expect(events.last.dig(:cost, :total)).to eq("0.047025")
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

    it "prices xAI and Mistral regional hosts and Priority tiers" do
      override_prices(
        "xai/grok-4.7" => { input: 2.0, output: 6.0, data_residency_input: 2.2, data_residency_output: 6.6,
                            priority_input: 4.0, priority_output: 12.0 },
        "mistral/mistral-medium-latest" => { input: 1.5, output: 7.5, data_residency_input: 1.65,
                                             data_residency_output: 8.25, priority_input: 2.625,
                                             priority_output: 13.125 }
      )
      tokens = { prompt_tokens: 10_000, completion_tokens: 1_000, total_tokens: 11_000 }
      {
        [:xai, "grok-4.7", "us.api.x.ai", {}] => ["data_residency", "0.0286"],
        [:xai, "grok-4.7", "api.x.ai", { service_tier: "priority" }] => ["priority", "0.052"],
        [:mistral, "mistral-medium-latest", "api.eu.mistral.ai", {}] => ["data_residency", "0.02475"],
        [:mistral, "mistral-medium-latest", "api.mistral.ai", { usage: tokens.merge(service_tier: "priority") }] =>
          ["priority", "0.039375"]
      }.each do |(provider, model, host, fields), (mode, total)|
        stub_openai_chat(id: "chatcmpl_#{host}", model: model, host: host, **{ usage: tokens }.merge(fields))
        context = RubyLLM.context do |config|
          config.public_send("#{provider}_api_key=", "test-#{provider}")
          config.public_send("#{provider}_api_base=", "https://#{host}/v1")
        end

        capture_sdk_events do |events|
          context.chat(model: model, provider: provider, assume_model_exists: true).ask("hi")
          expect(events.first).to include(provider: provider.to_s, pricing_mode: mode)
          expect(events.first.dig(:cost, :total)).to eq(total)
        end
      end
    end

    it "prices xAI reasoning tokens at the output rate, since xAI counts them outside output_tokens" do
      override_prices("xai/grok-4.7" => { input: 2.0, cache_read_input: 0.5, output: 6.0 })
      stub_openai_chat(id: "xai_reasoning", model: "grok-4.7", host: "api.x.ai",
                       usage: { prompt_tokens: 12_000, completion_tokens: 500, total_tokens: 15_000,
                                prompt_tokens_details: { cached_tokens: 8_000 },
                                completion_tokens_details: { reasoning_tokens: 2_500 } })

      capture_sdk_events do |events|
        RubyLLM.context { |config| config.xai_api_key = "test-xai" }
               .chat(model: "grok-4.7", provider: :xai, assume_model_exists: true).ask("hi")
        expect(events.first).to include(output_tokens: 3_000, hidden_output_tokens: 2_500)
        expect(events.first.dig(:cost, :total)).to eq("0.03")
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

    it "prices Gemini cached audio tokens from the raw usageMetadata at the audio caching rate" do
      LlmCostTrackerReset.call
      LlmCostTracker.configure do |config|
        config.instrument(:ruby_llm)
        config.pricing.overrides = {
          "gemini/gemini-2.5-flash" => { input: 0.3, audio_input: 1.0, cache_read_input: 0.03,
                                         audio_cache_read_input: 0.1, output: 2.5 }
        }
      end
      WebMock.stub_request(:post, %r{generativelanguage\.googleapis\.com/v1beta/models/gemini-2\.5-flash:generateContent})
             .to_return(
               status: 200,
               body: {
                 candidates: [{ content: { role: "model", parts: [{ text: "hi" }] }, finishReason: "STOP" }],
                 usageMetadata: { promptTokenCount: 100_000, cachedContentTokenCount: 80_000,
                                  candidatesTokenCount: 1_000,
                                  promptTokensDetails: [{ modality: "TEXT", tokenCount: 10_000 },
                                                        { modality: "AUDIO", tokenCount: 90_000 }],
                                  cacheTokensDetails: [{ modality: "TEXT", tokenCount: 8_000 },
                                                       { modality: "AUDIO", tokenCount: 72_000 }] },
                 modelVersion: "gemini-2.5-flash"
               }.to_json,
               headers: { "Content-Type" => "application/json" }
             )

      capture_sdk_events do |events|
        RubyLLM.chat(model: "gemini-2.5-flash", provider: :gemini, assume_model_exists: true).ask("hi")
        expect(events.first.dig(:cost, :total)).to eq("0.02854")
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

    it "prices a Gemini embedding from usageMetadata.promptTokenCount, which RubyLLM does not report" do
      override_prices("gemini/gemini-embedding-2" => { "input" => 0.20 })
      WebMock.stub_request(:post, %r{generativelanguage\.googleapis\.com/v1beta/models/gemini-embedding-2:batchEmbedContents})
             .to_return(status: 200, body: { embeddings: [{ values: [0.1] }], usageMetadata: { promptTokenCount: 500 } }.to_json,
                        headers: { "Content-Type" => "application/json" })

      capture_sdk_events do |events|
        RubyLLM.embed("hi", model: "gemini-embedding-2", provider: :gemini, assume_model_exists: true)
        expect(events.first).to include(provider: "gemini", input_tokens: 500)
        expect(events.first.dig(:cost, :total)).to eq("0.0001")
      end
    end
  end

  describe "paint" do
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

    it "prices a transcription's text prompt tokens at the text rate and its audio tokens at the audio rate" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/audio/transcriptions").to_return(
        status: 200,
        body: { text: "hi", usage: { type: "tokens", input_tokens: 1014, output_tokens: 150, total_tokens: 1164,
                                     input_token_details: { text_tokens: 14, audio_tokens: 1000 } } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        RubyLLM.transcribe(audio_file.path, model: "gpt-4o-transcribe", provider: :openai, assume_model_exists: true)
        expect(events.first).to include(input_tokens: 14, audio_input_tokens: 1000, output_tokens: 150)
        expect(events.first.dig(:cost, :total)).to eq("0.007535")
      end
    end

    it "records a plain-text transcription as unknown when RubyLLM retried a rate-limited attempt first" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/audio/transcriptions").to_return(
        { status: 429, body: { error: { message: "Rate limit reached" } }.to_json,
          headers: { "Content-Type" => "application/json" } },
        { status: 200, body: "hi", headers: { "Content-Type" => "text/plain" } }
      )

      capture_sdk_events do |events|
        RubyLLM.transcribe(audio_file.path, model: "whisper-1", provider: :openai, assume_model_exists: true)
        expect(events.first).to include(usage_source: "unknown", cost_status: "unknown", cost: nil)
      end
    end

    it "returns a plain-text transcription untouched and records it as unknown, since its body carries no usage" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/audio/transcriptions")
             .to_return(status: 200, body: "hi", headers: { "Content-Type" => "text/plain" })

      capture_sdk_events do |events|
        transcription = RubyLLM.transcribe(audio_file.path, model: "gpt-4o-transcribe", provider: :openai,
                                                            assume_model_exists: true)
        expect(transcription.text).to eq("hi")
        expect(events.first).to include(model: "gpt-4o-transcribe", usage_source: "unknown",
                                        cost_status: "unknown", cost: nil)
      end
    end

    it "prices a duration-billed transcription per billed minute of audio when RubyLLM reports no tokens" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/audio/transcriptions").to_return(
        status: 200,
        body: { text: "hi", duration: 89.6, usage: { type: "duration", seconds: 90 } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        RubyLLM.transcribe(audio_file.path, model: "gpt-transcribe", provider: :openai, assume_model_exists: true)
        line = events.first[:line_items].find { |item| item[:kind] == "transcription_minute" }
        expect(line[:quantity]).to eq("1.5")
        expect(events.first.dig(:cost, :total)).to eq("0.00675")
      end
    end

    it "rounds the audio duration up to whole seconds when the transcription has no usage.seconds" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/audio/transcriptions").to_return(
        status: 200,
        body: { text: "hi", duration: 8.47 }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        RubyLLM.transcribe(audio_file.path, model: "whisper-1", provider: :openai, assume_model_exists: true)
        expect(events.first.dig(:cost, :total)).to eq("0.0009")
      end
    end

    it "records a Gemini transcription once, although RubyLLM 1.x Gemini never calls Provider#transcribe" do
      url = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
      WebMock.stub_request(:post, url).to_return(
        status: 200,
        body: {
          candidates: [{ content: { role: "model", parts: [{ text: "hi" }] }, finishReason: "STOP" }],
          usageMetadata: { promptTokenCount: 40, candidatesTokenCount: 5, thoughtsTokenCount: 2,
                           promptTokensDetails: [{ modality: "TEXT", tokenCount: 10 }, { modality: "AUDIO", tokenCount: 30 }] }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        RubyLLM.transcribe(audio_file.path, model: "gemini-2.5-flash", provider: :gemini, assume_model_exists: true)
        expect(events.size).to eq(1)
        expect(events.first).to include(provider: "gemini", model: "gemini-2.5-flash", input_tokens: 10,
                                        audio_input_tokens: 30, output_tokens: 7)
        expect(events.first.dig(:cost, :total)).to eq("0.0000505")
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
