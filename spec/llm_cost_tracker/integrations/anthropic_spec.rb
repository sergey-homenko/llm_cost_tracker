# frozen_string_literal: true

require "spec_helper"
require "anthropic"

RSpec.describe LlmCostTracker::Integrations::Anthropic do
  before { configure_sdk_integration(:anthropic) }

  let(:client) { Anthropic::Client.new(api_key: "test-key") }
  let(:request_params) do
    { model: "claude-sonnet-4-5-20250929", max_tokens: 100, messages: [{ role: "user", content: "hi" }] }
  end

  describe "messages.create" do
    it "records token usage with cache TTL split from a real SDK response" do
      stub_sdk_json(:post, "https://api.anthropic.com/v1/messages",
                    provider: :anthropic, fixture: "messages_with_cache.json")

      capture_sdk_events do |events|
        response = client.messages.create(**request_params)

        expect(response).to be_a(Anthropic::Models::Message)
        expect(events.first).to include(
          provider: "anthropic",
          model: "claude-sonnet-4-5-20250929",
          input_tokens: 120,
          output_tokens: 35,
          cache_read_input_tokens: 50,
          cache_write_input_tokens: 20,
          cache_write_extended_input_tokens: 10,
          usage_source: "sdk_response",
          provider_response_id: "msg_123"
        )
      end
    end

    it "records thinking tokens as hidden output without inflating billable output" do
      stub_sdk_json(:post, "https://api.anthropic.com/v1/messages",
                    provider: :anthropic, fixture: "messages_with_thinking.json")

      capture_sdk_events do |events|
        client.messages.create(**request_params)

        expect(events.first).to include(
          output_tokens: 90,
          hidden_output_tokens: 64
        )
      end
    end

    it "preserves priority service tier as its own pricing mode so committed pricing isn't billed as standard" do
      stub_sdk_json(:post, "https://api.anthropic.com/v1/messages",
                    provider: :anthropic, fixture: "messages_priority_tier.json")

      capture_sdk_events do |events|
        client.messages.create(**request_params)
        expect(events.first[:pricing_mode]).to eq("priority")
      end
    end

    it "captures the batch service tier as a pricing mode" do
      stub_sdk_json(:post, "https://api.anthropic.com/v1/messages",
                    provider: :anthropic, fixture: "messages_batch_tier.json")

      capture_sdk_events do |events|
        client.messages.create(**request_params)
        expect(events.first[:pricing_mode]).to eq("batch")
      end
    end

    it "combines fast mode and US inference into fast_data_residency" do
      stub_sdk_json(:post, "https://api.anthropic.com/v1/messages",
                    provider: :anthropic, fixture: "messages_fast_data_residency.json")

      capture_sdk_events do |events|
        client.messages.create(model: "claude-opus-4-6", max_tokens: 100,
                               messages: [{ role: "user", content: "hi" }],
                               speed: "fast", inference_geo: "us")
        expect(events.first[:pricing_mode]).to eq("fast_data_residency")
      end
    end

    it "records server tool usage as service line items" do
      stub_sdk_json(:post, "https://api.anthropic.com/v1/messages",
                    provider: :anthropic, fixture: "messages_with_server_tools.json")

      capture_sdk_events do |events|
        client.messages.create(**request_params)

        service_lines = events.first[:line_items].reject { |item| item[:unit] == "token" }
        expect(service_lines.map { |item| item[:kind] }).to contain_exactly("web_search_request", "web_fetch_request")
        expect(service_lines.map { |item| item[:quantity].to_i }).to contain_exactly(2, 1)
      end
    end

    it "adds advisor iterations at the advisor model's rates" do
      stub_sdk_json(:post, "https://api.anthropic.com/v1/messages",
                    provider: :anthropic, fixture: "messages_with_advisor.json")

      capture_sdk_events do |events|
        client.messages.create(**request_params, model: "claude-sonnet-5")

        # advisor-tool#usage-and-billing example: Sonnet 5 executor $0.0089124 + Opus 5 advisor $0.044415.
        expect(events.first).to include(model: "claude-sonnet-5", input_tokens: 1_760, output_tokens: 531,
                                        cost_status: "complete")
        expect(BigDecimal(events.first[:cost][:total])).to eq(BigDecimal("0.0533274"))
      end
    end

    it "bills a fallback attempt declined before any output when its fallback block's category is billed" do
      stub_sdk_json(:post, %r{\Ahttps://api\.anthropic\.com/v1/messages},
                    provider: :anthropic, fixture: "messages_fallback.json")

      capture_sdk_events do |events|
        client.beta.messages.create(**request_params, model: "claude-fable-5",
                                                      betas: ["server-side-fallback-2026-07-01"])

        # refusals-and-fallback#what-the-response-contains example with a bio trigger:
        # Fable 5 535 x $10 = $0.00535 plus Opus 4.8 412 x $5 + 264 x $25 = $0.00866.
        expect(events.first).to include(model: "claude-opus-4-8", cost_status: "complete")
        expect(BigDecimal(events.first[:cost][:total])).to eq(BigDecimal("0.01401"))
      end
    end

    it "records a pre-output refusal in an unbilled category at $0" do
      stub_sdk_json(:post, "https://api.anthropic.com/v1/messages",
                    provider: :anthropic, fixture: "messages_refusal.json")

      capture_sdk_events do |events|
        client.messages.create(**request_params, model: "claude-fable-5")

        # refusals-and-fallback#how-refusals-are-billed: a cyber refusal before any output is not billed.
        expect(events.first).to include(input_tokens: 412, cost_status: "free")
        expect(BigDecimal(events.first[:cost][:total])).to eq(0)
      end
    end
  end

  describe "messages.batches.results_streaming" do
    let(:jsonl_body) do
      [
        { custom_id: "req_a",
          result: { type: "succeeded",
                    message: { id: "msg_a", type: "message", role: "assistant",
                               model: "claude-sonnet-4-5", content: [{ type: "text", text: "hi" }],
                               stop_reason: "end_turn", usage: { input_tokens: 10, output_tokens: 5 } } } },
        { custom_id: "req_b",
          result: { type: "errored",
                    error: { type: "invalid_request_error", message: "bad" } } }
      ].map(&:to_json).join("\n")
    end

    it "records each succeeded batch result as a ledger event with batch pricing_mode and skips errored ones" do
      WebMock.stub_request(:get, %r{https://api.anthropic.com/v1/messages/batches/batch_xyz/results}).to_return(
        status: 200,
        body: jsonl_body,
        headers: { "Content-Type" => "application/x-jsonl" }
      )

      capture_sdk_events do |events|
        client.messages.batches.results_streaming("batch_xyz").each { |_| }

        expect(events.size).to eq(1)
        expect(events.first).to include(
          provider: "anthropic",
          model: "claude-sonnet-4-5",
          pricing_mode: "batch",
          provider_response_id: "msg_a",
          usage_source: "sdk_batch_result"
        )
      end
    end

    it "prices a result with US inference_geo at batch data-residency rates" do
      result = { custom_id: "req_us",
                 result: { type: "succeeded",
                           message: { id: "msg_us", type: "message", role: "assistant",
                                      model: "claude-sonnet-4-6", content: [], stop_reason: "end_turn",
                                      usage: { input_tokens: 1_000, output_tokens: 500, cache_read_input_tokens: 20_000,
                                               service_tier: "batch", inference_geo: "us" } } } }
      WebMock.stub_request(:get, %r{https://api\.anthropic\.com/v1/messages/batches/batch_us/results}).to_return(
        status: 200,
        body: result.to_json,
        headers: { "Content-Type" => "application/x-jsonl" }
      )

      capture_sdk_events do |events|
        client.messages.batches.results_streaming("batch_us").each { |_| }

        expect(events.first[:pricing_mode]).to eq("batch_data_residency")
        # Sonnet 4.6 batch rates x 1.1 for US-only inference: $1.65 in, $8.25 out, $0.165 cache read per MTok.
        expect(BigDecimal(events.first[:cost][:total])).to eq(BigDecimal("0.009075"))
      end
    end

    it "records a refused result in an unbilled category at $0" do
      result = { custom_id: "req_refused",
                 result: { type: "succeeded",
                           message: { id: "msg_refused", type: "message", role: "assistant",
                                      model: "claude-fable-5-1", content: [], stop_reason: "refusal",
                                      stop_details: { type: "refusal", category: "general_harms", explanation: nil },
                                      usage: { input_tokens: 5_000, output_tokens: 0 } } } }
      WebMock.stub_request(:get, %r{https://api\.anthropic\.com/v1/messages/batches/batch_ref/results}).to_return(
        status: 200,
        body: result.to_json,
        headers: { "Content-Type" => "application/x-jsonl" }
      )

      capture_sdk_events do |events|
        client.messages.batches.results_streaming("batch_ref").each { |_| }

        # refusals-and-fallback#refusals-in-message-batches; general_harms refusals before any output are not billed.
        expect(events.first).to include(input_tokens: 5_000, cost_status: "free")
      end
    end

    it "skips a batch result whose provider_response_id already lives in the ledger so a second iteration is a no-op" do
      WebMock.stub_request(:get, %r{https://api.anthropic.com/v1/messages/batches/batch_xyz/results}).to_return(
        status: 200,
        body: jsonl_body,
        headers: { "Content-Type" => "application/x-jsonl" }
      )
      allow(LlmCostTracker::Call).to receive(:already_recorded?)
        .with(provider: "anthropic", provider_response_id: "msg_a")
        .and_return(true)

      capture_sdk_events do |events|
        client.messages.batches.results_streaming("batch_xyz").each { |_| }

        expect(events).to be_empty
      end
    end
  end

  describe "messages.stream / stream_raw" do
    let(:sse_body) do
      <<~SSE
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_stream_1","model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":120,"output_tokens":1}}}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":64}}

        event: message_stop
        data: {"type":"message_stop"}

      SSE
    end

    it "records token usage from a real SDK stream" do
      stub_sdk_sse(:post, "https://api.anthropic.com/v1/messages", body: sse_body)

      capture_sdk_events do |events|
        stream = client.messages.stream(**request_params)
        stream.each { |_| }

        expect(events.first).to include(
          provider: "anthropic",
          model: "claude-sonnet-4-5-20250929",
          input_tokens: 120,
          output_tokens: 64,
          stream: true,
          usage_source: "stream_final",
          provider_response_id: "msg_stream_1"
        )
      end
    end

    it "records token usage from stream_raw" do
      stub_sdk_sse(:post, "https://api.anthropic.com/v1/messages", body: sse_body)

      capture_sdk_events do |events|
        stream = client.messages.stream_raw(**request_params)
        stream.each { |_| }

        expect(events.first).to include(
          provider: "anthropic",
          input_tokens: 120,
          output_tokens: 64,
          stream: true,
          provider_response_id: "msg_stream_1"
        )
      end
    end

    it "prices cache writes added after message_start, such as server-tool breakpoints, at the 5-minute rate" do
      sse = <<~SSE
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_ws","model":"claude-sonnet-4-6","usage":{"input_tokens":79,"cache_creation_input_tokens":2600,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":2600},"output_tokens":3}}}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":79,"cache_creation_input_tokens":7924,"cache_read_input_tokens":2600,"output_tokens":510,"server_tool_use":{"web_search_requests":1}}}

        event: message_stop
        data: {"type":"message_stop"}

      SSE
      stub_sdk_sse(:post, "https://api.anthropic.com/v1/messages", body: sse)

      capture_sdk_events do |events|
        client.messages.stream(**request_params, model: "claude-sonnet-4-6").each { |_| nil }

        expect(events.first).to include(cache_write_input_tokens: 5324, cache_write_extended_input_tokens: 2600)
        # Sonnet 4.6: $3 in, $3.75 5m write, $6 1h write, $0.30 cache read, $15 out per MTok; $10 per 1,000 searches.
        expect(BigDecimal(events.first[:cost][:total])).to eq(BigDecimal("0.054232"))
      end
    end

    it "prices the speed the stream reports when a requested fast mode ran at standard speed" do
      sse = <<~SSE
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_speed","model":"claude-opus-4-6","usage":{"input_tokens":20000,"output_tokens":1,"speed":"standard"}}}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2000}}

        event: message_stop
        data: {"type":"message_stop"}

      SSE
      stub_sdk_sse(:post, "https://api.anthropic.com/v1/messages", body: sse)

      capture_sdk_events do |events|
        client.messages.stream(**request_params, model: "claude-opus-4-6", speed: "fast").each { |_| nil }

        expect(events.first).to include(pricing_mode: nil, cost_status: "complete")
        expect(BigDecimal(events.first[:cost][:total])).to eq(BigDecimal("0.15"))
      end
    end

    it "records a beta stream's mid-output fallback under the serving model with the declined attempt billed" do
      sse = <<~SSE
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_fb","type":"message","role":"assistant","model":"claude-fable-5-1","content":[],"usage":{"input_tokens":5000,"output_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"fallback","from":{"model":"claude-fable-5-1"},"to":{"model":"claude-opus-4-8"}}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":5200,"output_tokens":900,"iterations":[{"type":"message","model":"claude-fable-5-1","input_tokens":5000,"output_tokens":1200},{"type":"fallback_message","model":"claude-opus-4-8","input_tokens":5200,"output_tokens":900}]}}

        event: message_stop
        data: {"type":"message_stop"}

      SSE
      stub_sdk_sse(:post, %r{\Ahttps://api\.anthropic\.com/v1/messages}, body: sse)

      capture_sdk_events do |events|
        client.beta.messages.stream(**request_params, model: "claude-fable-5-1",
                                                      betas: ["server-side-fallback-2026-07-01"]).each { |_| nil }

        # refusals-and-fallback#streaming: Fable 5.1 5,000 x $10 + 1,200 x $50 plus Opus 4.8 5,200 x $5 + 900 x $25.
        expect(events.first).to include(model: "claude-opus-4-8", cost_status: "complete")
        expect(BigDecimal(events.first[:cost][:total])).to eq(BigDecimal("0.1585"))
      end
    end
  end

  describe "client-side refusal fallback middleware" do
    # refusals-and-fallback#how-refusals-are-billed: the refusal that triggered a fallback is billed in addition to
    # the fallback request when it arrived mid-stream or its category is billed.
    # Pricing: Fable 5.1 $10 in / $50 out, Opus 4.8 $5 in / $25 out per MTok.
    let(:client) do
      Anthropic::Client.new(api_key: "test-key", max_retries: 0, middleware: [
                              Anthropic::BetaRefusalFallbackMiddleware.new([{ model: "claude-opus-4-8" }])
                            ])
    end
    let(:params) do
      { model: "claude-fable-5-1", max_tokens: 100, messages: [{ role: "user", content: "hi" }],
        request_options: { fallback_state: Anthropic::BetaFallbackState.new } }
    end

    def refusal(category)
      { type: "refusal", category: category, explanation: nil, fallback_credit_token: "tok",
        fallback_has_prefill_claim: false }
    end

    def message(model, output_tokens, stop_details = nil)
      { status: 200, headers: { "Content-Type" => "application/json" },
        body: { id: "msg_#{model}", type: "message", role: "assistant", model: model,
                content: output_tokens.zero? ? [] : [{ type: "text", text: "x" }],
                stop_reason: stop_details ? "refusal" : "end_turn", stop_details: stop_details,
                usage: { input_tokens: 5_000, output_tokens: output_tokens } }.to_json }
    end

    def stream(model, output_tokens, stop_details = nil)
      start = { id: "msg_#{model}", type: "message", role: "assistant", model: model, content: [],
                usage: { input_tokens: 5_000, output_tokens: 1 } }
      events = [{ type: "message_start", message: start }]
      if output_tokens.positive?
        events << { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }
        events << { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "x" } }
        events << { type: "content_block_stop", index: 0 }
      end
      events << { type: "message_delta", usage: { input_tokens: 5_000, output_tokens: output_tokens },
                  delta: { stop_reason: stop_details ? "refusal" : "end_turn", stop_details: stop_details } }
      events << { type: "message_stop" }
      { status: 200, headers: { "Content-Type" => "text/event-stream" },
        body: events.map { |data| "event: #{data[:type]}\ndata: #{data.to_json}\n\n" }.join }
    end

    def stub_attempts(*responses)
      WebMock.stub_request(:post, %r{\Ahttps://api\.anthropic\.com/v1/messages}).to_return(*responses)
    end

    def total(events)
      events.sum { |event| BigDecimal(event[:cost][:total]) }
    end

    it "records a refusal the middleware retried as its own call" do
      stub_attempts(message("claude-fable-5-1", 0, refusal("bio")), message("claude-opus-4-8", 400))

      capture_sdk_events do |events|
        client.beta.messages.create(**params)

        # Fable 5.1 bio refusal 5,000 x $10 = $0.05, plus Opus 4.8 5,000 x $5 + 400 x $25 = $0.035.
        expect(events.map { |event| event[:model] }).to eq(%w[claude-fable-5-1 claude-opus-4-8])
        expect(total(events)).to eq(BigDecimal("0.085"))
      end
    end

    it "keeps the billed refusal when every model in the chain declines" do
      stub_attempts(message("claude-fable-5-1", 0, refusal("bio")),
                    message("claude-opus-4-8", 0, refusal("general_harms")))

      capture_sdk_events do |events|
        client.beta.messages.create(**params)

        # Fable 5.1 bio refusal $0.05; Opus 4.8's general_harms refusal before any output is not billed.
        expect(events.map { |event| event[:cost_status] }).to eq(%w[complete free])
        expect(total(events)).to eq(BigDecimal("0.05"))
      end
    end

    [false, true].each do |streaming|
      it "still records the served #{streaming ? 'stream' : 'call'} when a retried refusal crosses a raising budget" do
        allow(LlmCostTracker.configuration.budgets).to receive_messages(exceeded_behavior: :raise, per_call: 0.04)
        reply = streaming ? method(:stream) : method(:message)
        stub_attempts(reply.call("claude-fable-5-1", 0, refusal("bio")), reply.call("claude-opus-4-8", 400))

        capture_sdk_events do |events|
          streaming ? client.beta.messages.stream(**params).each { |_| nil } : client.beta.messages.create(**params)

          expect(events.map { |event| event[:model] }).to eq(%w[claude-fable-5-1 claude-opus-4-8])
        end
      end

      it "raises TransactionAbortedError from recording a retried refusal on a #{streaming ? 'stream' : 'call'}" do
        records = 0
        allow(LlmCostTracker::Tracker).to receive(:record).and_wrap_original do |original, **kwargs|
          records += 1
          raise LlmCostTracker::TransactionAbortedError, StandardError.new("deadlock") if records == 1

          original.call(**kwargs)
        end
        reply = streaming ? method(:stream) : method(:message)
        stub_attempts(reply.call("claude-fable-5-1", 0, refusal("bio")), reply.call("claude-opus-4-8", 400))

        expect do
          streaming ? client.beta.messages.stream(**params).each { |_| nil } : client.beta.messages.create(**params)
        end.to raise_error(LlmCostTracker::TransactionAbortedError)
      end
    end

    it "records a streamed refusal the middleware retried before any output as its own call" do
      stub_attempts(stream("claude-fable-5-1", 0, refusal("bio")), stream("claude-opus-4-8", 400))

      capture_sdk_events do |events|
        client.beta.messages.stream(**params).each { |_| nil }

        expect(events.map { |event| event[:model] }).to eq(%w[claude-fable-5-1 claude-opus-4-8])
        expect(total(events)).to eq(BigDecimal("0.085"))
      end
    end

    it "records a stream on which every model declined under the last model with the attempt that had output" do
      stub_attempts(stream("claude-fable-5-1", 300, refusal("cyber")),
                    stream("claude-opus-4-8", 0, refusal("general_harms")))

      capture_sdk_events do |events|
        client.beta.messages.stream(**params).each { |_| nil }

        # Fable 5.1 cyber refusal after 300 output tokens: 5,000 x $10 + 300 x $50 = $0.065.
        expect(events.size).to eq(1)
        expect(events.first).to include(model: "claude-opus-4-8", cost_status: "complete")
        expect(total(events)).to eq(BigDecimal("0.065"))
      end
    end
  end
end
