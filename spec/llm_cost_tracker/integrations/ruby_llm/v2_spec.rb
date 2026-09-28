# frozen_string_literal: true

require "spec_helper"
require "ruby_llm"
require "aws-eventstream"
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

  def anthropic_stream(usage:, delta_usage:, id: "msg_s", stop_reason: "end_turn")
    sse({ type: "message_start", message: anthropic_message(id: id, usage: usage).merge(content: [], stop_reason: nil) },
        { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
        { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "hi" } },
        { type: "content_block_stop", index: 0 },
        { type: "message_delta", delta: { stop_reason: stop_reason }, usage: delta_usage },
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
        expect(events.map { |event| event[:provider_response_id] }).to eq(%w[gen-1 gen-2])
        expect(costs(events)).to eq(%w[0.0063 0.0056])
      end
    end

    it "records each pause_turn segment as its own row, priced from its own response body" do
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
        chat("claude-sonnet-4-6", :anthropic).ask("research")
        expect(events.map { |event| event.values_at(:input_tokens, :cache_write_extended_input_tokens) })
          .to eq([[20, 8000], [30, 1500]])
        expect(events.map { |event| event[:provider_response_id] }).to eq(%w[msg_p1 msg_p2])
        expect(costs(events).sum { |total| BigDecimal(total) }).to eq(BigDecimal("0.06855"))
      end
    end
  end

  describe "request-derived pricing mode on attempts other than the last successful one" do
    it "prices every blocking pause_turn segment of a US-inference chat at data residency" do
      WebMock.stub_request(:post, messages_url).to_return(
        reply(anthropic_message(id: "msg_g1", usage: { input_tokens: 10_000, output_tokens: 1_000 },
                                stop_reason: "pause_turn")),
        reply(anthropic_message(id: "msg_g2", usage: { input_tokens: 10_000, output_tokens: 1_000 }))
      )

      capture_sdk_events do |events|
        chat("claude-sonnet-4-6", :anthropic).with_provider_options(inference_geo: "us").ask("research")
        expect(events.map { |event| event.values_at(:provider_response_id, :pricing_mode) })
          .to eq([%w[msg_g1 data_residency], %w[msg_g2 data_residency]])
      end
    end

    it "prices every blocking pause_turn segment of a fast-mode chat at the fast rate" do
      WebMock.stub_request(:post, messages_url).to_return(
        reply(anthropic_message(id: "msg_f1", model: "claude-opus-5-5", stop_reason: "pause_turn",
                                usage: { input_tokens: 10_000, output_tokens: 1_000 })),
        reply(anthropic_message(id: "msg_f2", model: "claude-opus-5-5",
                                usage: { input_tokens: 10_000, output_tokens: 1_000 }))
      )

      capture_sdk_events do |events|
        chat("claude-opus-5-5", :anthropic).with_provider_options(speed: "fast").ask("research")
        expect(events.map { |event| [event[:pricing_mode], event.dig(:cost, :total)] })
          .to eq([%w[fast 0.12], %w[fast 0.12]])
      end
    end

    it "prices a US-inference Anthropic stream cut off before its final usage at data residency" do
      WebMock.stub_request(:post, messages_url).to_return(anthropic_stream(
        id: "msg_cut", usage: { input_tokens: 10_000, output_tokens: 1 }, delta_usage: { output_tokens: 9 }
      ))

      capture_sdk_events do |events|
        cut = chat("claude-sonnet-4-6", :anthropic).with_provider_options(inference_geo: "us")
        expect { cut.ask("hi") { |_chunk| raise ArgumentError, "stop" } }.to raise_error(ArgumentError)
        expect(events.sole[:pricing_mode]).to eq("data_residency")
      end
    end
  end

  describe "streams priced from their events" do
    it "reads a streamed Anthropic chat's cumulative input, 1-hour cache writes, request inference geo and id" do
      WebMock.stub_request(:post, messages_url).to_return(anthropic_stream(
        usage: { input_tokens: 50, cache_creation_input_tokens: 2000, output_tokens: 1,
                 cache_creation: { ephemeral_5m_input_tokens: 0, ephemeral_1h_input_tokens: 2000 } },
        delta_usage: { input_tokens: 900, output_tokens: 300, server_tool_use: { web_search_requests: 1 } }
      ))

      capture_sdk_events do |events|
        chat("claude-sonnet-4-6", :anthropic).with_provider_options(inference_geo: "us").ask("news?") { |_chunk| }
        expect(events.sole).to include(stream: true, input_tokens: 900, cache_write_extended_input_tokens: 2000,
                                       output_tokens: 300, pricing_mode: "data_residency",
                                       usage_source: "sdk_response", provider_response_id: "msg_s")
        expect(fees(events.sole)).to eq(%w[web_search_request])
      end
    end

    it "records each streamed pause_turn segment from its own events" do
      search = { server_tool_use: { web_search_requests: 1 } }
      WebMock.stub_request(:post, messages_url).to_return(
        anthropic_stream(id: "msg_p1", usage: { input_tokens: 2679, output_tokens: 3 }, stop_reason: "pause_turn",
                         delta_usage: { input_tokens: 10_682, output_tokens: 510, **search }),
        anthropic_stream(id: "msg_p2", usage: { input_tokens: 11_200, output_tokens: 3 },
                         delta_usage: { input_tokens: 18_000, output_tokens: 700, **search })
      )

      capture_sdk_events do |events|
        chat("claude-sonnet-4-6", :anthropic).ask("research") { |_chunk| }
        expect(events.map { |event| event.values_at(:input_tokens, :output_tokens, :provider_response_id) })
          .to eq([[10_682, 510, "msg_p1"], [18_000, 700, "msg_p2"]])
        expect(costs(events)).to eq(%w[0.049696 0.0745])
      end
    end

    it "prices a streamed OpenAI chat at the tier its final event reports, with its tool calls and id" do
      response = response_object(id: "resp_s", model: "gpt-5-mini", usage: { input_tokens: 2000, output_tokens: 500 },
                                 service_tier: "flex",
                                 output: [{ type: "web_search_call", id: "ws_1", status: "completed",
                                            action: { type: "search", query: "q" } }])
      WebMock.stub_request(:post, "https://api.openai.com/v1/responses").to_return(sse(
        { type: "response.created",
          response: response.merge(status: "in_progress", service_tier: "auto", usage: nil, output: []) },
        { type: "response.output_item.done", output_index: 0, item: response[:output].first },
        { type: "response.completed", response: response }
      ))

      capture_sdk_events do |events|
        chat("gpt-5-mini", :openai).ask("news?") { |_chunk| }
        expect(events.sole).to include(stream: true, input_tokens: 2000, output_tokens: 500, pricing_mode: "flex",
                                       provider_response_id: "resp_s")
        expect(fees(events.sole)).to eq(%w[web_search_request])
      end
    end

    it "reads a streamed Gemini chat's audio and tool-use prompt tokens, grounding, tier header and id" do
      usage = { promptTokenCount: 19_210, candidatesTokenCount: 500, toolUsePromptTokenCount: 8000,
                promptTokensDetails: [{ modality: "TEXT", tokenCount: 10 }, { modality: "AUDIO", tokenCount: 19_200 }] }
      WebMock.stub_request(:post, gemini_url("gemini-2.5-flash", stream: true)).to_return(
        sse(gemini_body(usage, groundingMetadata: { webSearchQueries: %w[q1 q2] }))
          .merge(headers: { "Content-Type" => "text/event-stream", "x-gemini-service-tier" => "priority" })
      )

      capture_sdk_events do |events|
        chat("gemini-2.5-flash", :gemini).ask("news?") { |_chunk| }
        expect(events.sole).to include(stream: true, input_tokens: 8010, audio_input_tokens: 19_200,
                                       output_tokens: 500, pricing_mode: "priority", provider_response_id: "gem_1")
        expect(fees(events.sole)).to eq(%w[grounding_request])
      end
    end

    it "prices a Gemini chat on the Interactions protocol from the interaction's usage, blocking and streamed" do
      completed = { id: "v1_int", object: "interaction", model: "gemini-3.8-flash", status: "completed",
                    service_tier: "standard", steps: [{ type: "model_output", content: [{ type: "text", text: "hi" }] }],
                    usage: { total_input_tokens: 1000, total_output_tokens: 500, total_tokens: 1500,
                             grounding_tool_count: [{ type: "google_search", count: 2 }] } }
      WebMock.stub_request(:post, "https://generativelanguage.googleapis.com/v1beta/interactions").to_return(
        reply(completed),
        sse({ event_type: "interaction.created", interaction: completed.except(:usage, :steps).merge(status: "in_progress") },
            { event_type: "step.start", index: 0, step: { type: "model_output" } },
            { event_type: "step.delta", index: 0, delta: { type: "text", text: "hi" } },
            { event_type: "step.stop", index: 0 },
            { event_type: "interaction.completed", interaction: completed.except(:steps) })
      )

      capture_sdk_events do |events|
        travel_to(Time.utc(2026, 9, 27)) do
          2.times do |index|
            interactions = RubyLLM.chat(model: "gemini-3.8-flash", provider: :gemini, protocol: :interactions,
                                        assume_model_exists: true)
            index.zero? ? interactions.ask("hi") : interactions.ask("hi") { |_chunk| }
          end
        end
        expect(events.map { |event| event.values_at(:stream, :input_tokens, :output_tokens, :provider_response_id) })
          .to eq([[false, 1000, 500, "v1_int"], [true, 1000, 500, "v1_int"]])
        expect(costs(events)).to eq(%w[0.030625 0.030625])
      end
    end

    it "prices a streamed Chat Completions call on a regional Mistral host at the data-residency rate" do
      chunk = { id: "cmpl_ms", object: "chat.completion.chunk", model: "mistral-medium-latest" }
      WebMock.stub_request(:post, "https://api.eu.mistral.ai/v1/chat/completions").to_return(sse(
        chunk.merge(choices: [{ index: 0, delta: { role: "assistant", content: "hi" }, finish_reason: "stop" }]),
        chunk.merge(choices: [], usage: { prompt_tokens: 10_000, completion_tokens: 1_000, total_tokens: 11_000 })
      ))
      eu = RubyLLM.context do |config|
        config.mistral_api_key = "test-mistral"
        config.mistral_api_base = "https://api.eu.mistral.ai/v1"
      end

      capture_sdk_events do |events|
        chat("mistral-medium-latest", :mistral, context: eu).ask("hi") { |_chunk| }
        expect(events.sole).to include(stream: true, pricing_mode: "data_residency", provider_response_id: "cmpl_ms")
        expect(costs(events)).to eq(%w[0.02475])
      end
    end

    it "prices a stream cut off before its final usage event from RubyLLM's token counts" do
      WebMock.stub_request(:post, messages_url).to_return(anthropic_stream(
        usage: { input_tokens: 40, output_tokens: 1 }, delta_usage: { output_tokens: 9 }
      ))

      capture_sdk_events do |events|
        expect { chat("claude-sonnet-4-6", :anthropic).ask("hi") { |_chunk| raise ArgumentError, "stop" } }
          .to raise_error(ArgumentError, "stop")
        expect(events.sole).to include(stream: true, input_tokens: 40, usage_source: "sdk_response",
                                       provider_response_id: nil)
      end
    end

    it "prices a stream on a context's regional host from its events when the call raises after them" do
      response = response_object(id: "resp_eu", model: "gpt-5.4", usage: { input_tokens: 10_000, output_tokens: 1_000 })
      stream = sse({ type: "response.created", response: response.merge(status: "in_progress", usage: nil, output: []) },
                   { type: "response.output_text.delta", item_id: "msg_resp_eu", output_index: 0, content_index: 0,
                     delta: "hi" },
                   { type: "response.completed", response: response })
      WebMock.stub_request(:post, "https://eu.api.openai.com/v1/responses").to_return(stream, stream)
      eu = RubyLLM.context { |config| config.openai_api_base = "https://eu.api.openai.com/v1" }

      capture_sdk_events do |events|
        failing = chat("gpt-5.4", :openai, context: eu).after_message { raise ArgumentError, "save failed" }
        expect { failing.ask("hi") { |_chunk| } }.to raise_error(ArgumentError, "save failed")
        expect { chat("gpt-5.4", :openai, context: eu).ask("hi") { |chunk| raise "stop" if chunk.tokens&.input } }
          .to raise_error("stop")
        expect(events.map { |event| event.values_at(:stream, :pricing_mode, :provider_response_id) })
          .to eq([[true, "data_residency", "resp_eu"]] * 2)
        expect(costs(events)).to eq(%w[0.044 0.044])
      end
    end
  end

  describe "Bedrock Converse chats priced from their raw usage" do
    before do
      RubyLLM.configure do |config|
        config.bedrock_api_key = "AKIATEST"
        config.bedrock_secret_key = "test-secret"
        config.bedrock_region = "us-east-1"
      end
    end

    def converse_stream(usage)
      frames = [["messageStart", { role: "assistant" }], ["contentBlockDelta", { contentBlockIndex: 0, delta: { text: "hi" } }],
                ["messageStop", { stopReason: "end_turn" }], ["metadata", { usage: usage, metrics: { latencyMs: 120 } }]]
      body = frames.map do |type, data|
        headers = { ":message-type" => "event", ":event-type" => type, ":content-type" => "application/json" }
                  .transform_values { |value| Aws::EventStream::HeaderValue.new(value: value, type: "string") }
        Aws::EventStream::Encoder.new.encode(Aws::EventStream::Message.new(headers: headers,
                                                                          payload: StringIO.new(data.to_json)))
      end
      { status: 200, body: body.join, headers: { "Content-Type" => "application/vnd.amazon.eventstream" } }
    end

    it "splits a streamed chat's cache writes by its metadata event's cacheDetails, and leaves GovCloud unpriced" do
      usage = { inputTokens: 3000, outputTokens: 800, cacheReadInputTokens: 500, cacheWriteInputTokens: 4000,
                totalTokens: 8300, cacheDetails: [{ ttl: "1h", inputTokens: 3000 }, { ttl: "5m", inputTokens: 1000 }] }
      WebMock.stub_request(:post, %r{\Ahttps://bedrock-runtime\.[a-z0-9-]+\.amazonaws\.com/model/.+/converse-stream\z})
             .to_return(converse_stream(usage))
      govcloud = RubyLLM.context { |config| config.bedrock_region = "us-gov-west-1" }

      capture_sdk_events do |events|
        chat("us.anthropic.claude-sonnet-4-5-20250929-v1:0", :bedrock).ask("hi") { |_chunk| nil }
        chat("us-gov.anthropic.claude-sonnet-4-5-20250929-v1:0", :bedrock, context: govcloud).ask("hi") { |_chunk| nil }
        expect(events.map { |event| event.values_at(:model, :pricing_mode, :stream) })
          .to eq([["us.anthropic.claude-sonnet-4-5-20250929-v1:0", "data_residency", true],
                  ["us-gov.anthropic.claude-sonnet-4-5-20250929-v1:0", nil, true]])
        expect(events.map do |event|
          event.values_at(:input_tokens, :output_tokens, :cache_read_input_tokens, :cache_write_input_tokens,
                          :cache_write_extended_input_tokens)
        end).to all(eq([3000, 800, 500, 1000, 3000]))
        expect(costs(events)).to eq(["0.04719", nil])
      end
    end

    it "splits blocking cache writes by cacheDetails, or by with_caching's TTL when the body has none" do
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

    it "prices a batch result at its profile's batch rate by the submitted chat's model, apart from an outer chat" do
      body = { "output" => { "message" => { "role" => "assistant", "content" => [{ "text" => "hi" }] } },
               "stopReason" => "end_turn", "usage" => { "inputTokens" => 10_000, "outputTokens" => 1000 } }
      outer = { provider: "bedrock", model: "us.anthropic.claude-sonnet-4-5-20250929-v1:0" }

      { "us" => %w[us-east-1 batch_data_residency 0.02475], "global" => %w[sa-east-1 batch 0.0225] }
        .each do |geo, (region, mode, total)|
        context = RubyLLM.context { |config| config.bedrock_region = region }
        staged = chat("#{geo}.anthropic.claude-sonnet-4-5-20250929-v1:0", :bedrock, context: context).ask_later("hi")
        message = RubyLLM::Message.new(role: :assistant, content: "hi", raw: body, input_tokens: 10_000,
                                       output_tokens: 1000)
        allow(staged.provider).to receive(:batch_results).and_return([[0, message]])
        batch = RubyLLM::Batch.new(provider: staged.provider, chats: [staged], id: "job-#{geo}", raw_status: "Completed",
                                   completed: true)

        capture_sdk_events do |events|
          described_class.start("chat.ruby_llm", "1", outer)
          batch.messages
          described_class.finish("chat.ruby_llm", "1", outer)
          expect(events.sole).to include(model: staged.model.id, pricing_mode: mode, usage_source: "sdk_batch_result",
                                         provider_response_id: "job-#{geo}/0")
          expect(events.sole.dig(:cost, :total)).to eq(total)
        end
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

    it "prices a response RubyLLM rejects after the provider billed it from that response" do
      WebMock.stub_request(:post, "https://api.mistral.ai/v1/conversations").to_return(reply(
        conversation_id: "conv_1", object: "conversation.response",
        outputs: [{ type: "function.call", tool_call_id: "call_1", name: "lookup", arguments: "{}",
                    confirmation_status: "pending" }],
        usage: { prompt_tokens: 10_000, completion_tokens: 1_000, total_tokens: 11_000 }
      ))
      mistral = RubyLLM.context { |config| config.mistral_api_key = "test-mistral" }
      pending = mistral.chat(model: "mistral-medium-latest", provider: :mistral, protocol: :conversations,
                             assume_model_exists: true)

      capture_sdk_events do |events|
        expect { pending.ask("hi") }.to raise_error(RubyLLM::Error, /confirmation/)
        expect(events.sole).to include(input_tokens: 10_000, output_tokens: 1_000, usage_source: "sdk_response")
      end
    end

    it "records a Gemini chat that failed after the provider may have billed it as unknown" do
      WebMock.stub_request(:post, gemini_url("gemini-2.5-flash"))
             .to_return(reply({ error: { message: "boom" } }, status: 500))
      once = RubyLLM.context { |config| config.max_retries = 0 }

      capture_sdk_events do |events|
        expect { chat("gemini-2.5-flash", :gemini, context: once).ask("hi") }.to raise_error(RubyLLM::ServerError)
        expect(events.sole).to include(provider: "gemini", usage_source: "unknown", cost_status: "unknown")
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

    it "records an operation it has no event for at once, skips chat usage outside a chat, and flushes a leaked one" do
      tokens = RubyLLM::Tokens.new(input: 10, output: 5, reported_cost: 0.0042)
      usage = { operation: :chat, provider: "anthropic", model: "claude-sonnet-4-6", status: :succeeded, tokens: tokens }
      judgment = usage.merge(operation: :judgment, tokens: RubyLLM::Tokens.new(input: 30, output: 2))
      outer = { provider: "anthropic", model: "claude-sonnet-4-6" }
      leaked = outer.dup

      capture_sdk_events do |events|
        described_class.finish("usage.ruby_llm", "1", usage)
        described_class.start("chat.ruby_llm", "2", outer)
        described_class.start("chat.ruby_llm", "3", leaked)
        described_class.finish("usage.ruby_llm", "4", usage)
        described_class.finish("usage.ruby_llm", "5", judgment)
        expect(events.map { |event| event.values_at(:input_tokens, :usage_source) }).to eq([[30, "sdk_response"]])

        described_class.finish("chat.ruby_llm", "2", outer)
        expect(events.map { |event| event[:input_tokens] }).to eq([30, 10])
        expect(costs(events).last).to eq("0.0042")
        described_class.finish("chat.ruby_llm", "3", leaked)
        expect(events.size).to eq(2)
      end
    end

    it "prices a response body once, on the attempt RubyLLM bills rather than one it finishes empty before it" do
      body = anthropic_message(id: "msg_once", usage: { input_tokens: 10, output_tokens: 5 }).deep_stringify_keys
      raw = Faraday::Response.new(Faraday::Env.from(method: :post, url: URI(messages_url), request_body: "{}",
                                                    status: 200, body: body, response_headers: {}))
      usage = { operation: :chat, provider: "anthropic", model: "claude-sonnet-4-6", status: :succeeded,
                tokens: RubyLLM::Tokens.new(input: 10, output: 5) }
      payload = { provider: "anthropic", model: "claude-sonnet-4-6" }

      capture_sdk_events do |events|
        described_class.start("chat.ruby_llm", "1", payload)
        described_class.observe(:parse_completion_body, raw)
        described_class.finish("usage.ruby_llm", "2", usage.merge(tokens: RubyLLM::Tokens.new))
        described_class.finish("usage.ruby_llm", "3", usage)
        payload[:response] = RubyLLM::Message.new(role: :assistant, content: "hi", raw: raw)
        described_class.finish("chat.ruby_llm", "1", payload)
        expect(events.map { |event| event.values_at(:provider_response_id, :input_tokens) }).to eq([["msg_once", 10]])
      end
    end

    it "parses and looks up each batch result once per process however often the batch is read" do
      staged = chat("claude-sonnet-4-5", :anthropic).ask_later("hi")
      body = anthropic_message(id: "msg_b1", model: "claude-sonnet-4-5", usage: { input_tokens: 1000, output_tokens: 100 })
      message = RubyLLM::Message.new(role: :assistant, content: "hi", raw: body.deep_stringify_keys, input_tokens: 1000,
                                     output_tokens: 100)
      allow(staged.provider).to receive(:batch_results).and_return([[0, message]])
      allow(described_class::Attempt).to receive(:batch_event).and_call_original
      batch = RubyLLM::Batch.new(provider: staged.provider, chats: [staged], id: "msgbatch_once", raw_status: "ended",
                                 completed: true)

      capture_sdk_events do |events|
        3.times { batch.messages }
        batch.results
        batch.tokens
        batch.cost
        expect(events.sole).to include(provider_response_id: "msg_b1", usage_source: "sdk_batch_result")
      end
      expect(LlmCostTracker::Call).to have_received(:already_recorded?).once
      expect(described_class::Attempt).to have_received(:batch_event).once
    end

    it "records a batch embedding without usage as unknown and skips a chat result without usage" do
      gemini = chat("gemini-2.5-flash", :gemini).provider
      anthropic = chat("claude-sonnet-4-5", :anthropic).ask_later("hi")
      allow(gemini).to receive(:batch_results)
        .and_return([[0, RubyLLM::Embedding.new(vectors: [0.1], model: "gemini-embedding-001")]])
      allow(anthropic.provider).to receive(:batch_results)
        .and_return([[0, RubyLLM::Message.new(role: :assistant, content: "hi", model: "claude-sonnet-4-5")]])
      batches = [RubyLLM::Batch.new(provider: gemini, id: "batches/emb", raw_status: "JOB_STATE_SUCCEEDED",
                                    completed: true),
                 RubyLLM::Batch.new(provider: anthropic.provider, chats: [anthropic], id: "msgbatch_empty",
                                    raw_status: "ended", completed: true)]

      capture_sdk_events do |events|
        batches.each(&:messages)
        expect(events.sole).to include(provider: "gemini", model: "gemini-embedding-001", usage_source: "unknown",
                                       pricing_mode: "batch", provider_response_id: "batches/emb/0")
      end
    end

    it "raises a post-spend budget error for a batch result once it is recorded" do
      allow(LlmCostTracker.configuration.budgets).to receive_messages(exceeded_behavior: :raise, per_call: 0.000001)
      staged = chat("claude-sonnet-4-5", :anthropic).ask_later("hi")
      body = anthropic_message(id: "msg_over", model: "claude-sonnet-4-5", usage: { input_tokens: 1000, output_tokens: 100 })
      message = RubyLLM::Message.new(role: :assistant, content: "hi", raw: body.deep_stringify_keys, input_tokens: 1000,
                                     output_tokens: 100)
      allow(staged.provider).to receive(:batch_results).and_return([[0, message]])
      batch = RubyLLM::Batch.new(provider: staged.provider, chats: [staged], id: "msgbatch_over", raw_status: "ended",
                                 completed: true)

      capture_sdk_events do |events|
        expect { batch.messages }.to raise_error(LlmCostTracker::BudgetExceededError)
        expect(events.sole).to include(provider_response_id: "msg_over", usage_source: "sdk_batch_result")
      end
    end

    it "records nothing while the integration is not enabled" do
      LlmCostTrackerReset.call
      LlmCostTracker.configure { |config| config.pricing.unknown_model_behavior = :ignore }
      body = anthropic_message(id: "msg_off", usage: { input_tokens: 10, output_tokens: 5 })
      WebMock.stub_request(:post, messages_url).to_return(reply(body))
      staged = chat("claude-sonnet-4-6", :anthropic).ask_later("hi")
      message = RubyLLM::Message.new(role: :assistant, content: "hi", raw: body.deep_stringify_keys, input_tokens: 10,
                                     output_tokens: 5)
      allow(staged.provider).to receive(:batch_results).and_return([[0, message]])
      batch = RubyLLM::Batch.new(provider: staged.provider, chats: [staged], id: "msgbatch_off", raw_status: "ended",
                                 completed: true)
      judgment = { operation: :judgment, provider: "anthropic", model: "claude-sonnet-4-6", status: :succeeded,
                   tokens: RubyLLM::Tokens.new(input: 30, output: 2) }

      capture_sdk_events do |events|
        chat("claude-sonnet-4-6", :anthropic).ask("hi")
        batch.messages
        described_class.finish("usage.ruby_llm", "1", judgment)
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
        expect(events.sole[:tags]).to include(workflow_name: "Write article", workflow_step_name: "Draft")
      end
    end

    it "lets a :block_requests rule on workflow_name see the workflow before the call is sent" do
      seen = []
      allow(LlmCostTracker::Budget::PerTag).to receive(:blocking?).and_return(true)
      allow(LlmCostTracker::Budget::PerTag).to receive(:rules_for) { |tags, **| seen << tags.to_h && [] }
      WebMock.stub_request(:post, messages_url)
             .to_return(reply(anthropic_message(id: "msg_w", usage: { input_tokens: 1, output_tokens: 1 })))

      RubyLLM.workflow("Write article") do |workflow|
        workflow.step("Draft") { chat("claude-sonnet-4-6", :anthropic).ask("hi") }
      end

      expect(seen.first).to include(workflow_name: "Write article", workflow_step_name: "Draft")
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

    it "prices a Gemini embedding's text, PDF and video tokens from the raw usageMetadata RubyLLM does not report" do
      details = [{ modality: "TEXT", tokenCount: 5 }, { modality: "DOCUMENT", tokenCount: 258 },
                 { modality: "VIDEO", tokenCount: 2112 }]
      WebMock.stub_request(:post, %r{gemini-embedding-2:batchEmbedContents}).to_return(
        reply(embeddings: [{ values: [0.123456] }], usageMetadata: { promptTokenCount: 500 }),
        reply(embeddings: [{ values: [0.1] }], usageMetadata: { promptTokenCount: 2375, promptTokenDetails: details })
      )

      capture_sdk_events do |events|
        embedding = RubyLLM.embed("hi", model: "gemini-embedding-2", provider: :gemini, assume_model_exists: true)
        RubyLLM.embed("a talk", model: "gemini-embedding-2", provider: :gemini, assume_model_exists: true)
        expect(events.map { |event| event.values_at(:input_tokens, :image_input_tokens) }).to eq([[500, 0], [2117, 258]])
        expect(costs(events)).to eq(%w[0.0001 0.0254611])
        expect(embedding.to_json.scan("0.123456").size).to eq(1)
      end
    end

    it "splits gpt-image tokens, records a multi-image call once, and an image without usage as unknown" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/images/generations").to_return(
        reply(created: 1, data: [{ url: "https://example.com/a.png" }, { url: "https://example.com/b.png" }],
              usage: { input_tokens: 50, output_tokens: 200, input_tokens_details: { image_tokens: 30 },
                       output_tokens_details: { image_tokens: 160 } }),
        reply(created: 1, data: [{ b64_json: "iVBORw0KGgo=" }], usage: { input_tokens: 50, output_tokens: 4160 }),
        reply(created: 1, data: [{ b64_json: "iVBORw0KGgo=" }])
      )

      capture_sdk_events do |events|
        RubyLLM.paint("a cat", model: "gpt-image-1", count: 2)
        2.times { RubyLLM.paint("a fox", model: "gpt-image-1") }
        expect(events.map do |event|
          event.values_at(:input_tokens, :image_input_tokens, :output_tokens, :image_output_tokens)
        end).to eq([[20, 30, 40, 160], [50, 0, 0, 4160], [0, 0, 0, 0]])
        expect(events[1].dig(:cost, :total)).to eq("0.16665")
        expect(events.last).to include(usage_source: "unknown", cost_status: "unknown")
      end
    end

    it "prices Gemini native image output at the image rate and its text and thinking at the text rate" do
      model = "gemini-3.1-flash-image-preview"
      parts = [{ text: "Here is your fox." }, { inlineData: { mimeType: "image/png", data: "iVBORw0KGgo=" } }]
      WebMock.stub_request(:post, gemini_url(model)).to_return(reply(
        candidates: [{ content: { role: "model", parts: parts }, finishReason: "STOP" }],
        usageMetadata: { promptTokenCount: 12, candidatesTokenCount: 1145, thoughtsTokenCount: 180,
                         candidatesTokensDetails: [{ modality: "TEXT", tokenCount: 25 },
                                                   { modality: "IMAGE", tokenCount: 1120 }] },
        modelVersion: model
      ))

      capture_sdk_events do |events|
        RubyLLM.paint("a watercolor fox", model: model, provider: :gemini, assume_model_exists: true)
        expect(events.sole).to include(input_tokens: 12, output_tokens: 205, image_output_tokens: 1120,
                                       hidden_output_tokens: 180)
        expect(events.sole.dig(:cost, :total)).to eq("0.067821")
      end
    end

    it "prices transcription audio and prompt tokens apart, and a duration by the billed minute" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/audio/transcriptions").to_return(
        reply(text: "hi", usage: { type: "tokens", input_tokens: 1014, output_tokens: 150, total_tokens: 1164,
                                   input_token_details: { text_tokens: 14, audio_tokens: 1000 } }),
        reply(text: "hi", duration: 89.6, usage: { type: "duration", seconds: 90 })
      )
      WebMock.stub_request(:post, gemini_url("gemini-2.5-flash")).to_return(reply(
        candidates: [{ content: { role: "model", parts: [{ text: "hi" }] }, finishReason: "STOP" }],
        usageMetadata: { promptTokenCount: 40, candidatesTokenCount: 5, thoughtsTokenCount: 2,
                         promptTokensDetails: [{ modality: "TEXT", tokenCount: 10 }, { modality: "AUDIO", tokenCount: 30 }] }
      ))

      capture_sdk_events do |events|
        %w[openai/gpt-4o-transcribe openai/gpt-transcribe gemini/gemini-2.5-flash].each do |name|
          provider, model = name.split("/")
          RubyLLM.transcribe(audio.path, model: model, provider: provider.to_sym, assume_model_exists: true)
        end
        expect(events.map { |event| event.values_at(:input_tokens, :audio_input_tokens, :output_tokens) })
          .to eq([[14, 1000, 150], [0, 0, 0], [10, 30, 7]])
        expect(events[1][:line_items].find { |item| item[:kind] == "transcription_minute" }[:quantity]).to eq("1.5")
        expect(costs(events)).to eq(%w[0.007535 0.00675 0.0000505])
      end
    end

    it "prices a streamed transcription from its final event, even when the block raises on it, and one cut off " \
       "before it as streamed" do
      usage = { input_tokens: 1014, output_tokens: 150, total_tokens: 1164,
                input_token_details: { text_tokens: 14, audio_tokens: 1000 } }
      options = { model: "gpt-4o-transcribe", provider: :openai, assume_model_exists: true }
      done = sse({ type: "transcript.text.delta", delta: "hi" },
                 { type: "transcript.text.done", text: "hi", usage: usage })
      WebMock.stub_request(:post, "https://api.openai.com/v1/audio/transcriptions")
             .to_return(done, sse({ type: "transcript.text.delta", delta: "hi" }), done)

      capture_sdk_events do |events|
        2.times { RubyLLM.transcribe(audio.path, **options) { nil } }
        expect { RubyLLM.transcribe(audio.path, **options) { |chunk| raise "stop" if chunk.done? } }
          .to raise_error("stop")
        expect(events.map { |event| event.values_at(:stream, :input_tokens, :audio_input_tokens, :usage_source) })
          .to eq([[true, 14, 1000, "sdk_response"], [true, 0, 0, "unknown"], [true, 14, 1000, "sdk_response"]])
        expect(costs(events)).to eq(["0.007535", nil, "0.007535"])
      end
    end

    it "skips a refused streamed transcription attempt and records a maybe-billed one as unknown, streamed" do
      done = sse({ type: "transcript.text.done", text: "hi", usage: { type: "duration", seconds: 60 } })
      WebMock.stub_request(:post, "https://api.openai.com/v1/audio/transcriptions").to_return(
        reply({ error: { message: "slow down" } }, status: 429), reply({ error: { message: "boom" } }, status: 500), done
      )

      capture_sdk_events do |events|
        RubyLLM.transcribe(audio.path, model: "gpt-transcribe", provider: :openai, assume_model_exists: true,
                                       context: no_retry_delay) { nil }
        expect(events.map { |event| event.values_at(:stream, :usage_source) })
          .to eq([[true, "unknown"], [true, "sdk_response"]])
      end
    end

    it "prices a transcription streamed through a context's regional host at data residency" do
      WebMock.stub_request(:post, "https://eu.api.openai.com/v1/audio/transcriptions")
             .to_return(sse({ type: "transcript.text.done", text: "hi", usage: { type: "duration", seconds: 60 } }))
      eu = RubyLLM.context { |config| config.openai_api_base = "https://eu.api.openai.com/v1" }

      capture_sdk_events do |events|
        eu.transcribe(audio.path, model: "gpt-transcribe", provider: :openai, assume_model_exists: true) { nil }
        expect(events.sole).to include(stream: true, pricing_mode: "data_residency")
        expect(costs(events)).to eq(%w[0.00495])
      end
    end

    it "records a transcription streamed over a WebSocket as streamed" do
      pcm = "\0\0" * 1600
      audio.binmode
      audio.write(["RIFF", 36 + pcm.bytesize, "WAVE", "fmt ", 16, 1, 1, 16_000, 32_000, 2, 16, "data", pcm.bytesize]
                    .pack("a4Va4a4VvvVVvva4V"), pcm)
      audio.flush
      replies = {
        "api.x.ai" => [{ type: "transcript.created" }, { type: "transcript.done", text: "hi", duration: 0.1 }],
        "api.elevenlabs.io" => [{ message_type: "committed_transcript_with_timestamps", text: "hi", words: [] }],
        "api.deepgram.com" => [{ type: "Results", is_final: true, channel: { alternatives: [{ transcript: "hi" }] } },
                               { type: "Metadata", duration: 0.1 }],
        "generativelanguage.googleapis.com" => [{ setupComplete: {} },
                                                { serverContent: { inputTranscription: { text: "hi" } } },
                                                { serverContent: { generationComplete: true },
                                                  usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 2 } }]
      }
      socket = Struct.new(:replies) do
        def each_message(write:)
          writer = Thread.new { write.call(self) }
          replies.each { |reply| yield reply.to_json }
          writer.join(5)
        end

        def send_text(*) = nil
        def send_binary(*) = nil
        def close = nil
      end
      allow(RubyLLM::Transport::WebsocketConnection).to receive(:open) do |url, **, &block|
        block.call(socket.new(replies.fetch(URI(url).host)))
      end
      keys = RubyLLM.context { |config| config.xai_api_key = config.elevenlabs_api_key = config.deepgram_api_key = "test" }
      models = { xai: "grok-stt", elevenlabs: "scribe_v2_realtime", deepgram: "nova-3",
                 gemini: "gemini-3.5-transcribe-live" }

      capture_sdk_events do |events|
        models.each do |provider, model|
          keys.transcribe(audio.path, model: model, provider: provider, assume_model_exists: true) { nil }
        end
        expect(events.map { |event| event.values_at(:provider, :stream) })
          .to eq(models.keys.map { |provider| [provider.to_s, true] })
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

    it "records moderation at no cost, tts-1 speech by its characters, and speech without usage as unknown" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/moderations").to_return(reply(
        id: "modr_x", model: "omni-moderation-latest", results: [{ flagged: false, categories: {}, category_scores: {} }]
      ))
      WebMock.stub_request(:post, "https://api.openai.com/v1/audio/speech")
             .to_return(status: 200, body: "ID3".b, headers: { "Content-Type" => "audio/mpeg" })

      capture_sdk_events do |events|
        RubyLLM.moderate("hi", model: "omni-moderation-latest")
        %w[tts-1 gpt-4o-mini-tts].each do |model|
          RubyLLM.speak("Hello there", model: model, provider: :openai, assume_model_exists: true)
        end
        expect(events.map { |event| event.values_at(:model, :usage_source, :cost_status) })
          .to eq([%w[omni-moderation-latest sdk_response free], %w[tts-1 sdk_response complete],
                  %w[gpt-4o-mini-tts unknown unknown]])
        expect(events.first[:provider_response_id]).to eq("modr_x")
        expect(events[1][:line_items].sole).to include(kind: "text_to_speech_character", quantity: "11.0")
        expect(costs(events)[1]).to eq("0.000165")
      end
    end

    it "prices Gemini speech from its usageMetadata, and a body RubyLLM rejects for missing audio from its usage" do
      model = "gemini-2.5-flash-preview-tts"
      usage = { promptTokenCount: 11, candidatesTokenCount: 107,
                promptTokensDetails: [{ modality: "TEXT", tokenCount: 11 }],
                candidatesTokensDetails: [{ modality: "AUDIO", tokenCount: 107 }] }
      audio = { content: { role: "model", parts: [{ inlineData: { mimeType: "audio/pcm", data: "AAAA" } }] } }
      WebMock.stub_request(:post, gemini_url(model)).to_return(
        reply(candidates: [audio], usageMetadata: usage, modelVersion: model, responseId: "tts_1"),
        reply(candidates: [{ finishReason: "OTHER" }], usageMetadata: usage.slice(:promptTokenCount))
      )
      options = { model: model, provider: :gemini, assume_model_exists: true }

      capture_sdk_events do |events|
        RubyLLM.speak("Say hi", **options)
        expect { RubyLLM.speak("Say hi", **options) }.to raise_error(RubyLLM::Error, /Unexpected response format/)
        expect(events.map { |event| event.values_at(:input_tokens, :audio_output_tokens, :usage_source) })
          .to eq([[11, 107, "sdk_response"], [11, 0, "sdk_response"]])
        expect(events.first[:provider_response_id]).to eq("tts_1")
        expect(costs(events)).to eq(%w[0.0010755 0.0000055])
      end
    end

    it "reads Vertex AI usageMetadata for Gemini speech and gemini-embedding-2 image and video tokens" do
      allow_any_instance_of(RubyLLM::Providers::VertexAI).to receive(:headers).and_return({})
      vertex = RubyLLM.context do |config|
        config.vertexai_project_id = "proj"
        config.vertexai_location = "us-central1"
      end
      models = %r{aiplatform\.googleapis\.com/v1beta1/projects/proj/locations/us-central1/publishers/google/models}
      WebMock.stub_request(:post, /#{models}\/gemini-2.5-flash-preview-tts:generateContent\z/).to_return(reply(
        candidates: [{ content: { role: "model", parts: [{ inlineData: { mimeType: "audio/pcm", data: "AAAA" } }] } }],
        usageMetadata: { promptTokenCount: 11, candidatesTokenCount: 107,
                         candidatesTokensDetails: [{ modality: "AUDIO", tokenCount: 107 }] }
      ))
      WebMock.stub_request(:post, /#{models}\/gemini-embedding-2:embedContent\z/).to_return(reply(
        embedding: { values: [0.1] },
        usageMetadata: { promptTokenCount: 1261, promptTokensDetails: [{ modality: "IMAGE", tokenCount: 258 },
                                                                       { modality: "VIDEO", tokenCount: 1000 },
                                                                       { modality: "TEXT", tokenCount: 3 }] }
      ))
      options = { provider: :vertexai, assume_model_exists: true, context: vertex }

      capture_sdk_events do |events|
        RubyLLM.speak("Say hi", model: "gemini-2.5-flash-preview-tts", **options)
        RubyLLM.embed("a cat", model: "gemini-embedding-2", **options)
        expect(events.map { |event| event.values_at(:model, :input_tokens, :image_input_tokens, :audio_output_tokens) })
          .to eq([["gemini-2.5-flash-preview-tts", 11, 0, 107], ["gemini-embedding-2", 1003, 258, 0]])
        expect(events.map { |event| event[:provider] }).to eq(%w[vertexai vertexai])
        expect(costs(events)).to eq(%w[0.0010755 0.0121167])
      end
    end

    it "records the storage of a Gemini context cache created with RubyLLM.cache once, not on find, renew, or " \
       "a create without usage" do
      url = "https://generativelanguage.googleapis.com/v1beta/cachedContents"
      cache = { name: "cachedContents/abc123", model: "models/gemini-2.5-flash", createTime: "2026-09-27T10:00:00.123456Z",
                expireTime: "2026-09-27T11:00:00.123456Z", usageMetadata: { totalTokenCount: 250_000 } }
      WebMock.stub_request(:post, url).to_return(reply(cache), reply(cache.except(:usageMetadata)))
      WebMock.stub_request(:get, "#{url}/abc123").to_return(reply(cache))
      WebMock.stub_request(:patch, "#{url}/abc123").to_return(reply(cache))

      capture_sdk_events do |events|
        created = RubyLLM.cache("document", model: "gemini-2.5-flash", provider: :gemini, ttl: 3600)
        RubyLLM::CachedContent.find(created.name, provider: :gemini).renew(ttl: 3600)
        RubyLLM.cache("document", model: "gemini-2.5-flash", provider: :gemini, ttl: 3600)
        expect(events.sole).to include(model: "gemini-2.5-flash", provider_response_id: "cachedContents/abc123")
        expect(events.sole.dig(:cost, :total)).to eq("0.25")
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

    it "warns that the integration is not installed before it subscribes" do
      subscriptions = described_class.instance_variable_get(:@subscriptions)
      described_class.instance_variable_set(:@subscriptions, nil)

      expect(described_class.status)
        .to have_attributes(status: :warn, message: "ruby_llm integration is enabled but not installed")
    ensure
      described_class.instance_variable_set(:@subscriptions, subscriptions)
    end

    it "warns when RubyLLM instruments through something else" do
      custom = Object.new
      RubyLLM.config.instrumenter = custom

      expect(described_class.status).to have_attributes(status: :warn, message: /instrumenter is #<Object.+not recorded/)
    ensure
      RubyLLM.config.instrumenter = ActiveSupport::Notifications
    end

    it "subscribes and bridges each RubyLLM seam once however often it is installed" do
      bridge = described_class::BuildChunkBridge

      expect { described_class.install }
        .not_to(change { ActiveSupport::Notifications.notifier.listeners_for("usage.ruby_llm").size })
      expect(RubyLLM::Protocols::Anthropic.ancestors.count(bridge)).to eq(1)
      expect(RubyLLM::Protocols::Anthropic.instance_method(:build_chunk).owner).to eq(bridge)
      expect(RubyLLM::Batch.ancestors.count(described_class::BatchBridge)).to eq(1)
      expect(RubyLLM::Providers::VertexAI::EmbedContent.instance_method(:parse_embedding_response).owner)
        .to eq(described_class::ParseEmbeddingResponseBridge)
    end

    it "skips a RubyLLM seam that is missing and names it in doctor" do
      seams = described_class::SEAMS.merge(build_chunk: %w[Protocols::Anthropic Protocols::Deepgram Protocols::Gone])
      stub_const("#{described_class}::SEAMS", seams)

      expect { described_class.install }.not_to raise_error
      expect(RubyLLM::Protocols::Deepgram.private_method_defined?(:build_chunk)).to be(false)
      expect(described_class.status).to have_attributes(
        status: :warn, message: /not read: RubyLLM::Protocols::Deepgram#build_chunk, RubyLLM::Protocols::Gone#build_chunk\z/
      )
    end

    it "keeps a RubyLLM call running when reading its seam fails, and prices it from RubyLLM's token and tool counts" do
      WebMock.stub_request(:post, messages_url).to_return(anthropic_stream(
        usage: { input_tokens: 40, output_tokens: 1 },
        delta_usage: { output_tokens: 9, server_tool_use: { web_search_requests: 1 } }
      ))
      allow(described_class::Attempt).to receive(:stream_window).and_raise(StandardError, "window broke")
      allow(LlmCostTracker::Logging).to receive(:warn)

      capture_sdk_events do |events|
        expect(chat("claude-sonnet-4-6", :anthropic).ask("hi") { |_chunk| }.content).to eq("hi")
        expect(events.sole).to include(input_tokens: 40, output_tokens: 9, provider_response_id: nil)
        expect(fees(events.sole)).to eq(%w[web_search_request])
      end
      expect(LlmCostTracker::Logging).to have_received(:warn).with(/window broke/).at_least(:once)
    end

    it "cannot be installed when RubyLLM is not loaded" do
      hide_const("RubyLLM")

      expect(described_class.status).to have_attributes(status: :warn, message: /RubyLLM is not loaded/)
    end
  end
end
