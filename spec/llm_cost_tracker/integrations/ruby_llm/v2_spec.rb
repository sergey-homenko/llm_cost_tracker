# frozen_string_literal: true

require "spec_helper"
require "ruby_llm"
require "tempfile"

RSpec.describe LlmCostTracker::Integrations::RubyLlm::V2, unless: RubyLLM::VERSION.start_with?("1.") do
  let(:json) { { "Content-Type" => "application/json" } }
  let(:messages_url) { "https://api.anthropic.com/v1/messages" }

  before do
    configure_sdk_integration(:ruby_llm)
    RubyLLM.configure do |config|
      config.openai_api_key = "test-openai"
      config.anthropic_api_key = "test-anthropic"
      config.gemini_api_key = "test-gemini"
      config.openrouter_api_key = "test-openrouter"
    end
  end

  def chat(model, provider, context: RubyLLM)
    context.chat(model: model, provider: provider, assume_model_exists: true)
  end

  def no_retry_delay = RubyLLM.context { |config| config.retry_interval = config.retry_interval_randomness = 0 }

  def reply(body = {}, status: 200, headers: {}, **fields)
    { status: status, body: body.merge(fields).to_json, headers: json.merge(headers) }
  end

  def sse(*events)
    body = events.map { |event| "data: #{event.to_json}\n\n" }.join
    { status: 200, body: body, headers: { "Content-Type" => "text/event-stream" } }
  end

  def anthropic_message(id:, usage:, model: "claude-sonnet-4-6", stop_reason: "end_turn")
    { id: id, type: "message", role: "assistant", model: model, content: [{ type: "text", text: "hi" }],
      stop_reason: stop_reason, usage: usage }
  end

  def anthropic_stream(usage:, delta_usage:)
    sse({ type: "message_start", message: anthropic_message(id: "msg_s", usage: usage).merge(content: []) },
        { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
        { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "hi" } },
        { type: "content_block_stop", index: 0 },
        { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: delta_usage },
        { type: "message_stop" })
  end

  def response_object(id:, usage:, model: "gpt-4o", output: nil, **extra)
    { id: id, object: "response", status: "completed", model: model, usage: usage, **extra,
      output: output || [{ type: "message", id: "msg_#{id}", status: "completed", role: "assistant",
                           content: [{ type: "output_text", text: "hi", annotations: [] }] }] }
  end

  def gemini_url(model, stream: false)
    base = "https://generativelanguage.googleapis.com/v1beta/models/#{model}"
    stream ? "#{base}:streamGenerateContent?alt=sse" : "#{base}:generateContent"
  end

  def gemini_body(usage, model: "gemini-2.5-flash", **candidate)
    { candidates: [{ content: { role: "model", parts: [{ text: "hi" }] }, finishReason: "STOP", **candidate }],
      usageMetadata: usage, modelVersion: model, responseId: "gem_1" }
  end

  def costs(events) = events.map { |event| event.dig(:cost, :total) }

  def fees(event) = event[:line_items].reject { |item| item[:unit] == "token" }.map { |item| item[:kind] }

  describe "blocking chats priced from the raw response body" do
    it "reads an OpenAI Responses body with its cached and reasoning tokens and response id" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/responses").to_return(reply(response_object(
        id: "resp_1", usage: { input_tokens: 100, output_tokens: 30, total_tokens: 130,
                               input_tokens_details: { cached_tokens: 25 },
                               output_tokens_details: { reasoning_tokens: 8 } }
      )))

      capture_sdk_events do |events|
        RubyLLM.chat(model: "gpt-4o").ask("hi")
        expect(events.sole).to include(provider: "openai", model: "gpt-4o", input_tokens: 75, cache_read_input_tokens: 25,
                                       output_tokens: 30, hidden_output_tokens: 8, stream: false,
                                       usage_source: "sdk_response", provider_response_id: "resp_1")
        expect(events.sole[:latency_ms]).to be_a(Integer)
      end
    end

    it "records nothing when the response carries no usage" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/responses")
             .to_return(reply(response_object(id: "resp_2", usage: nil)))

      capture_sdk_events do |events|
        RubyLLM.chat(model: "gpt-4o").ask("hi")
        expect(events).to be_empty
      end
    end

    it "prices Anthropic tiers, speed, US inference and the 1-hour cache split from the body" do
      {
        { input_tokens: 10_000, output_tokens: 1_000, inference_geo: "us" } => %w[data_residency 0.0495],
        { input_tokens: 10_000, output_tokens: 1_000, speed: "fast" } => %w[fast 0.12],
        { input_tokens: 10, output_tokens: 5,
          cache_creation: { ephemeral_5m_input_tokens: 100, ephemeral_1h_input_tokens: 200 } } => [nil, "0.00168"]
      }.each do |usage, (mode, total)|
        model = usage[:speed] ? "claude-opus-5-5" : "claude-sonnet-4-6"
        WebMock.stub_request(:post, messages_url)
               .to_return(reply(anthropic_message(id: "msg_#{total}", model: model, usage: usage)))

        capture_sdk_events do |events|
          chat(model, :anthropic).ask("hi")
          expect(events.sole).to include(pricing_mode: mode, provider_response_id: "msg_#{total}")
          expect(events.sole.dig(:cost, :total)).to eq(total)
        end
      end
    end

    it "prices Anthropic advisor and fallback iterations and $0 refusals, as the Anthropic SDK does" do
      {
        "messages_with_advisor.json" => ["claude-sonnet-5", "0.0533274", "complete"],
        "messages_fallback.json" => ["claude-opus-4-8", "0.01401", "complete"],
        "messages_refusal.json" => ["claude-fable-5", "0.0", "free"]
      }.each do |fixture, (model, total, status)|
        WebMock.stub_request(:post, messages_url)
               .to_return(status: 200, body: sdk_fixture(:anthropic, fixture), headers: json)

        capture_sdk_events do |events|
          chat(model, :anthropic).ask("hi")
          expect(events.sole).to include(model: model, cost_status: status)
          expect(BigDecimal(events.sole.dig(:cost, :total))).to eq(BigDecimal(total))
        end
      end
    end

    it "reads Gemini audio, url_context tool-use tokens, grounding and the service-tier header from the body" do
      usage = { promptTokenCount: 19_210, candidatesTokenCount: 500, toolUsePromptTokenCount: 8000,
                promptTokensDetails: [{ modality: "TEXT", tokenCount: 10 }, { modality: "AUDIO", tokenCount: 19_200 }] }
      WebMock.stub_request(:post, gemini_url("gemini-2.5-flash")).to_return(reply(
        gemini_body(usage, groundingMetadata: { webSearchQueries: %w[q1 q2] }), headers: { "x-gemini-service-tier" => "flex" }
      ))

      capture_sdk_events do |events|
        chat("gemini-2.5-flash", :gemini).ask("hi")
        expect(events.sole).to include(input_tokens: 8010, audio_input_tokens: 19_200, output_tokens: 500,
                                       pricing_mode: "flex", provider_response_id: "gem_1")
        expect(fees(events.sole)).to eq(%w[grounding_request])
      end
    end

    it "prices a regional OpenAI host and a Mistral priority tier, including a host set on a context" do
      WebMock.stub_request(:post, "https://eu.api.openai.com/v1/responses").to_return(reply(response_object(
        id: "resp_eu", model: "gpt-5.4", usage: { input_tokens: 10_000, output_tokens: 1_000, total_tokens: 11_000 }
      )))
      WebMock.stub_request(:post, "https://api.mistral.ai/v1/chat/completions").to_return(reply(
        id: "cmpl_m", object: "chat.completion", model: "mistral-medium-latest",
        choices: [{ index: 0, message: { role: "assistant", content: "hi" }, finish_reason: "stop" }],
        usage: { prompt_tokens: 10_000, completion_tokens: 1_000, total_tokens: 11_000, service_tier: "priority" }
      ))
      eu = RubyLLM.context { |config| config.openai_api_base = "https://eu.api.openai.com/v1" }
      mistral = RubyLLM.context { |config| config.mistral_api_key = "test-mistral" }

      capture_sdk_events do |events|
        chat("gpt-5.4", :openai, context: eu).ask("hi")
        chat("mistral-medium-latest", :mistral, context: mistral).ask("hi")
        expect(events.map { |event| event.values_at(:provider, :pricing_mode) })
          .to eq([%w[openai data_residency], %w[mistral priority]])
        expect(costs(events).first).to eq("0.044")
      end
    end

    it "records OpenRouter's billed usage.cost, adding the upstream cost of a BYOK call, blocking and streamed" do
      usage = { prompt_tokens: 1000, completion_tokens: 200, total_tokens: 1200, cost: 0.0003, is_byok: true,
                cost_details: { upstream_inference_cost: 0.006 } }
      chunk = { id: "gen-2", object: "chat.completion.chunk", model: "deepseek/deepseek-v3.2" }
      WebMock.stub_request(:post, "https://openrouter.ai/api/v1/chat/completions").to_return(
        reply(id: "gen-1", object: "chat.completion", model: "deepseek/deepseek-v3.2", usage: usage,
              choices: [{ index: 0, message: { role: "assistant", content: "hi" }, finish_reason: "stop" }]),
        sse(chunk.merge(choices: [{ index: 0, delta: { content: "hi" }, finish_reason: "stop" }]),
            chunk.merge(choices: [], usage: usage.merge(cost: 0.0056, is_byok: false)))
      )

      capture_sdk_events do |events|
        chat("deepseek/deepseek-v3.2", :openrouter).ask("hi")
        chat("deepseek/deepseek-v3.2", :openrouter).ask("hi") { |_chunk| }
        expect(events.map { |event| fees(event) }).to eq([%w[billed_request], %w[billed_request]])
        expect(costs(events)).to eq(%w[0.0063 0.0056])
      end
    end

    it "records each pause_turn segment as its own row, earlier ones from RubyLLM's tokens at the chat's cache TTL" do
      segment = lambda do |id, usage, stop_reason = "end_turn"|
        reply(anthropic_message(id: id, usage: usage, stop_reason: stop_reason))
      end
      WebMock.stub_request(:post, messages_url).to_return(
        segment.call("msg_p1", { input_tokens: 20, output_tokens: 200, cache_creation_input_tokens: 8000,
                                 cache_creation: { ephemeral_5m_input_tokens: 0, ephemeral_1h_input_tokens: 8000 } },
                     "pause_turn"),
        segment.call("msg_p2", { input_tokens: 30, output_tokens: 400, cache_read_input_tokens: 8000,
                                 cache_creation_input_tokens: 1500,
                                 cache_creation: { ephemeral_5m_input_tokens: 0, ephemeral_1h_input_tokens: 1500 } })
      )

      capture_sdk_events do |events|
        chat("claude-sonnet-4-6", :anthropic).with_caching(ttl: "1h").ask("research")
        expect(events.map { |event| event.values_at(:input_tokens, :cache_write_extended_input_tokens) })
          .to eq([[20, 8000], [30, 1500]])
        expect(events.map { |event| event[:provider_response_id] }).to eq([nil, "msg_p2"])
        expect(costs(events).sum { |total| BigDecimal(total) }).to eq(BigDecimal("0.06855"))
      end
    end
  end

  describe "chats priced from RubyLLM's normalized tokens" do
    before do
      RubyLLM.configure do |config|
        config.bedrock_api_key = "AKIATEST"
        config.bedrock_secret_key = "test-secret"
        config.bedrock_region = "us-east-1"
      end
    end

    it "splits Bedrock cache writes by cacheDetails, or by with_caching's TTL when the body has none" do
      usage = { inputTokens: 3000, cacheWriteInputTokens: 4000, outputTokens: 800, totalTokens: 7800 }
      bodies = [usage.merge(cacheDetails: [{ ttl: "1h", inputTokens: 3000 }, { ttl: "5m", inputTokens: 1000 }]), usage]
      WebMock.stub_request(:post, %r{\Ahttps://bedrock-runtime\.us-east-1\.amazonaws\.com/model/.+/converse\z})
             .to_return(*bodies.map do |body|
               reply(output: { message: { role: "assistant", content: [{ text: "hi" }] } }, stopReason: "end_turn",
                     usage: body)
             end)
      model = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"

      capture_sdk_events do |events|
        chat(model, :bedrock).ask("hi")
        chat(model, :bedrock).with_caching(ttl: "1h").ask("hi")
        expect(events.map { |event| event.values_at(:input_tokens, :cache_write_input_tokens) })
          .to eq([[3000, 1000], [3000, 0]])
        expect(events.map { |event| event[:cache_write_extended_input_tokens] }).to eq([3000, 4000])
        expect(events.map { |event| event[:pricing_mode] }).to all(eq("data_residency"))
      end
    end

    it "prices a streamed Anthropic chat's server tools, request inference geo and cache TTL" do
      WebMock.stub_request(:post, messages_url).to_return(anthropic_stream(
        usage: { input_tokens: 50, cache_creation_input_tokens: 2000, output_tokens: 1 },
        delta_usage: { output_tokens: 300, server_tool_use: { web_search_requests: 1 } }
      ))

      capture_sdk_events do |events|
        chat("claude-sonnet-4-6", :anthropic).with_caching(ttl: "1h").with_provider_options(inference_geo: "us")
                                            .ask("news?") { |_chunk| }
        expect(events.sole).to include(stream: true, input_tokens: 50, cache_write_extended_input_tokens: 2000,
                                       output_tokens: 300, pricing_mode: "data_residency",
                                       usage_source: "sdk_response")
        expect(fees(events.sole)).to eq(%w[web_search_request])
      end
    end

    it "prices a streamed OpenAI chat's tool calls and requested service tier" do
      response = response_object(id: "resp_s", model: "gpt-5-mini", usage: { input_tokens: 2000, output_tokens: 500 },
                                 output: [{ type: "web_search_call", id: "ws_1", status: "completed",
                                            action: { type: "search", query: "q" } }])
      WebMock.stub_request(:post, "https://api.openai.com/v1/responses").to_return(sse(
        { type: "response.created", response: response.merge(status: "in_progress", usage: nil, output: []) },
        { type: "response.output_item.done", output_index: 0, item: response[:output].first },
        { type: "response.completed", response: response }
      ))

      capture_sdk_events do |events|
        chat("gpt-5-mini", :openai).with_provider_options(service_tier: "flex").ask("news?") { |_chunk| }
        expect(events.sole).to include(stream: true, input_tokens: 2000, output_tokens: 500, pricing_mode: "flex")
        expect(fees(events.sole)).to eq(%w[web_search_request])
      end
    end

    it "prices a streamed Gemini chat's grounding and its service-tier header" do
      usage = { promptTokenCount: 1000, candidatesTokenCount: 500 }
      WebMock.stub_request(:post, gemini_url("gemini-2.5-flash", stream: true)).to_return(
        sse(gemini_body(usage, groundingMetadata: { webSearchQueries: %w[q1 q2] }))
          .merge(headers: { "Content-Type" => "text/event-stream", "x-gemini-service-tier" => "priority" })
      )

      capture_sdk_events do |events|
        chat("gemini-2.5-flash", :gemini).ask("news?") { |_chunk| }
        expect(events.sole).to include(stream: true, input_tokens: 1000, output_tokens: 500, pricing_mode: "priority")
        expect(fees(events.sole)).to eq(%w[grounding_request])
      end
    end
  end

  describe "attempts" do
    it "skips a refused attempt, records a maybe-billed one as unknown, and prices the one that succeeded" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/responses").to_return(
        reply({ error: { message: "slow down" } }, status: 429),
        reply({ error: { message: "boom" } }, status: 500),
        reply(response_object(id: "resp_ok", usage: { input_tokens: 10, output_tokens: 5, total_tokens: 15 }))
      )

      capture_sdk_events do |events|
        chat("gpt-4o", :openai, context: no_retry_delay).ask("hi")
        expect(events.map { |event| event.values_at(:usage_source, :provider_response_id) })
          .to eq([["unknown", nil], %w[sdk_response resp_ok]])
        expect(events.first).to include(provider: "openai", model: "gpt-4o", cost_status: "unknown")
      end
    end

    it "records nothing for a request the provider refused, and lets its error through" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/responses")
             .to_return(reply({ error: { message: "bad" } }, status: 400))

      capture_sdk_events do |events|
        expect { chat("gpt-4o", :openai).ask("hi") }.to raise_error(RubyLLM::BadRequestError)
        expect(events).to be_empty
      end
    end

    it "keeps the caller's exception when a post-spend budget error would replace it" do
      allow(LlmCostTracker.configuration.budgets).to receive_messages(exceeded_behavior: :raise, per_call: 0.000001)
      WebMock.stub_request(:post, messages_url)
             .to_return(reply(anthropic_message(id: "msg_b", usage: { input_tokens: 10, output_tokens: 5 })))
      failing = chat("claude-sonnet-4-6", :anthropic).after_message { raise ArgumentError, "callback failed" }

      capture_sdk_events do |events|
        expect { failing.ask("hi") }.to raise_error(ArgumentError, "callback failed")
        expect { chat("claude-sonnet-4-6", :anthropic).ask("hi") }.to raise_error(LlmCostTracker::BudgetExceededError)
        expect(events.size).to eq(2)
      end
    end

    it "attributes each attempt to its innermost operation" do
      WebMock.stub_request(:post, messages_url).to_return(anthropic_stream(
        usage: { input_tokens: 40, output_tokens: 1 }, delta_usage: { output_tokens: 9 }
      ))
      WebMock.stub_request(:post, "https://api.openai.com/v1/embeddings").to_return(reply(
        object: "list", model: "text-embedding-3-small", data: [{ embedding: [0.1] }],
        usage: { prompt_tokens: 7, total_tokens: 7 }
      ))

      capture_sdk_events do |events|
        embedded = false
        chat("claude-sonnet-4-6", :anthropic).ask("hi") do |_chunk|
          next if embedded

          embedded = RubyLLM.embed("hi", model: "text-embedding-3-small", provider: :openai, assume_model_exists: true)
        end
        expect(events.map { |event| event.values_at(:model, :input_tokens) })
          .to eq([["text-embedding-3-small", 7], ["claude-sonnet-4-6", 40]])
      end
    end

    it "records usage outside any operation at once, and flushes an inner operation whose finish never came" do
      tokens = RubyLLM::Tokens.new(input: 10, output: 5)
      usage = { operation: :chat, provider: "anthropic", model: "claude-sonnet-4-6", status: :succeeded, tokens: tokens }
      outer = { provider: "anthropic", model: "claude-sonnet-4-6" }
      leaked = outer.dup

      capture_sdk_events do |events|
        described_class.finish("usage.ruby_llm", "1", usage)
        described_class.start("chat.ruby_llm", "2", outer)
        described_class.start("chat.ruby_llm", "3", leaked)
        described_class.finish("usage.ruby_llm", "4", usage)
        expect(events.size).to eq(1)

        described_class.finish("chat.ruby_llm", "2", outer)
        expect(events.map { |event| event[:input_tokens] }).to eq([10, 10])
        described_class.finish("chat.ruby_llm", "3", leaked)
        expect(events.size).to eq(2)
      end
    end

    it "records nothing while the integration is not enabled" do
      LlmCostTrackerReset.call
      LlmCostTracker.configure { |config| config.pricing.unknown_model_behavior = :ignore }
      WebMock.stub_request(:post, messages_url)
             .to_return(reply(anthropic_message(id: "msg_off", usage: { input_tokens: 10, output_tokens: 5 })))

      capture_sdk_events do |events|
        chat("claude-sonnet-4-6", :anthropic).ask("hi")
        expect(events).to be_empty
      end
    end

    it "tags calls with the RubyLLM workflow and step" do
      WebMock.stub_request(:post, messages_url)
             .to_return(reply(anthropic_message(id: "msg_w", usage: { input_tokens: 10, output_tokens: 5 })))

      capture_sdk_events do |events|
        RubyLLM.workflow("Write article", id: "article-42") do |workflow|
          workflow.step("Draft") { chat("claude-sonnet-4-6", :anthropic).ask("hi") }
        end
        expect(events.sole[:tags]).to include(workflow: "Write article", workflow_step: "Draft")
      end
    end

    it "logs and keeps the call when recording fails" do
      WebMock.stub_request(:post, messages_url)
             .to_return(reply(anthropic_message(id: "msg_f", usage: { input_tokens: 10, output_tokens: 5 })))
      allow(LlmCostTracker::Tracker).to receive(:record).and_raise(StandardError, "ledger down")
      allow(LlmCostTracker::Logging).to receive(:warn)

      expect(chat("claude-sonnet-4-6", :anthropic).ask("hi").content).to eq("hi")
      expect(LlmCostTracker::Logging).to have_received(:warn).with(/failed to record usage: StandardError: ledger down/)
    end
  end

  describe "budget preflight" do
    before do
      allow(LlmCostTracker.configuration.budgets).to receive_messages(exceeded_behavior: :block_requests, per_call: 0.001)
    end

    it "blocks a chat, attachment text included, and an embedding before sending them" do
      image = Tempfile.new(["pic", ".png"], binmode: true)
      image.write("\x89PNG\r\n\x1a\n".b + ("\x00".b * 64))
      image.flush

      [-> { RubyLLM.chat(model: "gpt-4o").ask("x" * 400_000, with: image.path) },
       -> { RubyLLM.embed("x" * 400_000, model: "text-embedding-3-small") }].each do |call|
        expect { call.call }.to raise_error(
          an_instance_of(LlmCostTracker::BudgetExceededError).and(having_attributes(stage: :pre_send))
        )
      end
      expect(WebMock).not_to have_requested(:post, /api\.openai\.com/)
    ensure
      image&.close!
    end
  end

  describe "one-shot operations" do
    let(:audio) { Tempfile.new(["clip", ".wav"]) }

    after { audio.close! }

    it "records an embedding, and one without usage as unknown" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/embeddings").to_return(reply(
        object: "list", model: "text-embedding-3-small", data: [{ embedding: [0.1] }],
        usage: { prompt_tokens: 7, total_tokens: 7 }
      ))
      WebMock.stub_request(:post, %r{gemini-embedding-001:batchEmbedContents})
             .to_return(reply(embeddings: [{ values: [0.1] }]))

      capture_sdk_events do |events|
        RubyLLM.embed("hi", model: "text-embedding-3-small")
        RubyLLM.embed("hi", model: "gemini-embedding-001", provider: :gemini, assume_model_exists: true)
        expect(events.map { |event| event.values_at(:model, :input_tokens, :usage_source) })
          .to eq([["text-embedding-3-small", 7, "sdk_response"], ["gemini-embedding-001", 0, "unknown"]])
      end
    end

    it "prices image output as image tokens, and an image without usage as unknown" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/images/generations").to_return(
        reply(created: 1, data: [{ b64_json: "iVBORw0KGgo=" }], usage: { input_tokens: 50, output_tokens: 4160 }),
        reply(created: 1, data: [{ b64_json: "iVBORw0KGgo=" }])
      )

      capture_sdk_events do |events|
        2.times { RubyLLM.paint("a fox", model: "gpt-image-1") }
        expect(events.first).to include(input_tokens: 50, output_tokens: 0, image_output_tokens: 4160)
        expect(events.first.dig(:cost, :total)).to eq("0.16665")
        expect(events.last).to include(usage_source: "unknown", cost_status: "unknown")
      end
    end

    it "prices transcription tokens at the audio rate, and a duration by the billed minute" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/audio/transcriptions").to_return(
        reply(text: "hi", usage: { type: "tokens", input_tokens: 1000, output_tokens: 150, total_tokens: 1150 }),
        reply(text: "hi", duration: 89.6, usage: { type: "duration", seconds: 90 })
      )

      capture_sdk_events do |events|
        RubyLLM.transcribe(audio.path, model: "gpt-4o-transcribe", provider: :openai, assume_model_exists: true)
        RubyLLM.transcribe(audio.path, model: "gpt-transcribe", provider: :openai, assume_model_exists: true)
        expect(events.first).to include(input_tokens: 0, audio_input_tokens: 1000, output_tokens: 150)
        expect(events.last[:line_items].find { |item| item[:kind] == "transcription_minute" }[:quantity]).to eq("1.5")
        expect(costs(events)).to eq(%w[0.0075 0.00675])
      end
    end

    it "records a plain-text transcription retried after a rate limit once, as unknown" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/audio/transcriptions").to_return(
        reply({ error: { message: "Rate limit reached" } }, status: 429),
        { status: 200, body: "hi", headers: { "Content-Type" => "text/plain" } }
      )

      capture_sdk_events do |events|
        RubyLLM.transcribe(audio.path, model: "whisper-1", provider: :openai, assume_model_exists: true,
                                       context: no_retry_delay)
        expect(events.sole).to include(usage_source: "unknown", cost_status: "unknown")
      end
    end

    it "records moderation at no cost and a speech call RubyLLM reports no usage for as unknown" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/moderations").to_return(reply(
        id: "modr_x", model: "omni-moderation-latest", results: [{ flagged: false, categories: {}, category_scores: {} }]
      ))
      WebMock.stub_request(:post, "https://api.openai.com/v1/audio/speech")
             .to_return(status: 200, body: "ID3".b, headers: { "Content-Type" => "audio/mpeg" })

      capture_sdk_events do |events|
        RubyLLM.moderate("hi", model: "omni-moderation-latest")
        RubyLLM.speak("hi", model: "gpt-4o-mini-tts", provider: :openai, assume_model_exists: true)
        expect(events.map { |event| event.values_at(:model, :usage_source, :provider_response_id) })
          .to eq([%w[omni-moderation-latest sdk_response modr_x], ["gpt-4o-mini-tts", "unknown", nil]])
        expect(events.first[:cost_status]).to eq("free")
      end
    end
  end

  describe "install and status" do
    it "routes RubyLLM through ActiveSupport::Notifications and reports it" do
      RubyLLM.config.instrumenter = nil
      described_class.install

      expect(RubyLLM.config.instrumenter).to eq(ActiveSupport::Notifications)
      expect(described_class.status).to have_attributes(status: :ok, message: "ruby_llm integration installed")
    end

    it "warns when RubyLLM instruments through something else" do
      custom = Object.new
      RubyLLM.config.instrumenter = custom

      expect(described_class.status).to have_attributes(status: :warn, message: /instrumenter is #<Object.+not recorded/)
    ensure
      RubyLLM.config.instrumenter = ActiveSupport::Notifications
    end

    it "subscribes once however often it is installed" do
      expect { described_class.install }
        .not_to(change { ActiveSupport::Notifications.notifier.listeners_for("usage.ruby_llm").size })
    end

    it "cannot be installed when RubyLLM is not loaded" do
      hide_const("RubyLLM")

      expect(described_class.status).to have_attributes(status: :warn, message: /RubyLLM is not loaded/)
    end
  end
end
