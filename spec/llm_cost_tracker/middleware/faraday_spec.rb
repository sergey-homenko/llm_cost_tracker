# frozen_string_literal: true

require "spec_helper"
require "faraday"

RSpec.describe LlmCostTracker::Middleware::Faraday do
  before do
    allow(LlmCostTracker::Ingestion::Inbox).to receive(:save).and_return(true)
    allow(LlmCostTracker::Ledger::Store).to receive(:insert).and_return(true)
  end

  let(:openai_response_body) do
    {
      id: "chatcmpl_sync_123",
      model: "gpt-4o",
      choices: [{ message: { content: "Hello!" } }],
      usage: {
        prompt_tokens: 10,
        completion_tokens: 5,
        total_tokens: 15
      }
    }.to_json
  end

  let(:connection) do
    Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker, tags: { feature: "test" }
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") do
          [200, { "Content-Type" => "application/json" }, openai_response_body]
        end
      end
    end
  end

  it "tracks LLM API calls via Faraday" do
    events = []
    ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
      events << payload
    end

    connection.post("/v1/chat/completions", { model: "gpt-4o" }.to_json)

    expect(events.size).to eq(1)
    expect(events.first[:provider]).to eq("openai")
    expect(events.first[:model]).to eq("gpt-4o")
    expect(events.first.dig(:token_usage, :input_tokens)).to eq(10)
    expect(events.first.dig(:token_usage, :output_tokens)).to eq(5)
    expect(events.first[:cost]).not_to be_nil
    expect(events.first[:latency_ms]).to be_a(Integer)
    expect(events.first[:latency_ms]).to be >= 0
    expect(events.first[:provider_response_id]).to eq("chatcmpl_sync_123")
    expect(events.first[:tags]).to include(feature: "test")
  end

  it "tracks responses that Faraday has already parsed as JSON" do
    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") do
          [
            200,
            { "Content-Type" => "application/json" },
            {
              model: "gpt-4o",
              usage: {
                prompt_tokens: 10,
                completion_tokens: 5,
                total_tokens: 15
              }
            }
          ]
        end
      end
    end

    events = []
    ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
      events << payload
    end

    conn.post("/v1/chat/completions", { model: "gpt-4o" })

    expect(events.size).to eq(1)
    expect(events.first[:model]).to eq("gpt-4o")
  end

  it "supports callable tags evaluated per request" do
    current_user_id = 42
    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker, tags: -> { { feature: "chat", user_id: current_user_id } }
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") do
          [200, { "Content-Type" => "application/json" }, openai_response_body]
        end
      end
    end

    events = []
    ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
      events << payload
    end

    conn.post("/v1/chat/completions", { model: "gpt-4o" }.to_json)

    expect(events.first[:tags]).to include(feature: "chat", user_id: 42)
  end

  it "snapshots callable tags before the response completes" do
    current_user_id = 42
    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker, tags: -> { { user_id: current_user_id } }
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") do
          current_user_id = 99
          [200, { "Content-Type" => "application/json" }, openai_response_body]
        end
      end
    end

    events = []
    ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
      events << payload
    end

    conn.post("/v1/chat/completions", { model: "gpt-4o" }.to_json)

    expect(events.first[:tags]).to include(user_id: 42)
  end

  it "does not break requests when tag snapshot fails" do
    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker, tags: -> { raise "missing request context" }
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") do
          [200, { "Content-Type" => "application/json" }, openai_response_body]
        end
      end
    end

    events = []
    ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
      events << payload
    end

    log = capture_log do
      response = conn.post("/v1/chat/completions", { model: "gpt-4o" }.to_json)
      expect(response.status).to eq(200)
    end

    expect(log).to match(/Error resolving request tags: RuntimeError: missing request context/)
    expect(events.first[:tags]).to eq({})
  end

  it "passes the Faraday request env to callable tags when accepted" do
    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker, tags: ->(env) { { path: env.url.path } }
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") do
          [200, { "Content-Type" => "application/json" }, openai_response_body]
        end
      end
    end

    events = []
    ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
      events << payload
    end

    conn.post("/v1/chat/completions", { model: "gpt-4o" }.to_json)

    expect(events.first[:tags]).to include(path: "/v1/chat/completions")
  end

  it "does not break requests when tracking is disabled" do
    LlmCostTracker.configuration.enabled = false

    response = connection.post("/v1/chat/completions", { model: "gpt-4o" }.to_json)
    expect(response.status).to eq(200)
  end

  it "does not interfere with non-LLM requests" do
    conn = Faraday.new(url: "https://example.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.get("/api/users") { [200, {}, '{"users": []}'] }
      end
    end

    events = []
    ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
      events << payload
    end

    response = conn.get("/api/users")
    expect(response.status).to eq(200)
    expect(events).to be_empty
  end

  it "warns when a supported response body cannot be read" do
    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") do
          [200, { "Content-Type" => "text/event-stream" }, proc {}]
        end
      end
    end

    log = capture_log do
      conn.post("/v1/chat/completions", { model: "gpt-4o" }.to_json)
    end

    expect(log).to match(/known streaming responses are captured automatically/)
  end

  it "removes query strings from warning URLs" do
    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") do
          [200, { "Content-Type" => "text/event-stream" }, proc {}]
        end
      end
    end

    log = capture_log do
      conn.post("/v1/chat/completions?api_key=secret-token", { model: "gpt-4o" }.to_json)
    end

    expect(log).to include("https://api.openai.com/v1/chat/completions;")
    expect(log).not_to include("secret-token")
  end

  it "raises budget errors from post-response enforcement" do
    LlmCostTracker.configure do |config|
      config.budgets.monthly = 0.000001
      config.budgets.exceeded_behavior = :raise
    end
    allow(LlmCostTracker::Ledger::Period::Totals).to receive(:call).and_return(month: 0.000075)

    expect do
      connection.post("/v1/chat/completions", { model: "gpt-4o" }.to_json)
    end.to raise_error(LlmCostTracker::BudgetExceededError)
  end

  it "raises unknown pricing errors from post-response enforcement" do
    LlmCostTracker.configure do |config|
      config.pricing.unknown_model_behavior = :raise
    end

    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") do
          body = {
            model: "unknown-chat-model",
            usage: {
              prompt_tokens: 10,
              completion_tokens: 5,
              total_tokens: 15
            }
          }.to_json

          [200, { "Content-Type" => "application/json" }, body]
        end
      end
    end

    expect do
      conn.post("/v1/chat/completions", { model: "unknown-chat-model" }.to_json)
    end.to raise_error(LlmCostTracker::UnknownPricingError)
  end

  it "records a fully received stream once, without a synthetic interrupted-stream event, before raising UnknownPricingError" do
    LlmCostTracker.configure { |config| config.pricing.unknown_model_behavior = :raise }

    sse_body = "data: {\"id\":\"chatcmpl_x\",\"model\":\"unknown-chat-model\"," \
               "\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}\n\n" \
               "data: [DONE]\n\n"
    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") { [200, { "Content-Type" => "text/event-stream" }, sse_body] }
      end
    end

    events = []
    ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
      events << payload
    end

    expect do
      conn.post("/v1/chat/completions", { model: "unknown-chat-model", stream: true }.to_json)
    end.to raise_error(LlmCostTracker::UnknownPricingError)

    expect(events.size).to eq(1)
    expect(events.first[:tags]).not_to have_key(:stream_interrupted)
  end

  it "captures streaming OpenAI responses through the on_data tap" do
    sse_body = "data: " \
               "{\"id\":\"chatcmpl_stream_123\",\"model\":\"gpt-4o\"," \
               "\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n" \
               "data: {\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":2,\"total_tokens\":9}}\n\n" \
               "data: [DONE]\n\n"

    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") do |env|
          env.request.on_data&.call(sse_body, sse_body.bytesize, env)
          [200, { "Content-Type" => "text/event-stream" }, sse_body]
        end
      end
    end

    events = []
    ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
      events << payload
    end

    conn.post("/v1/chat/completions", { model: "gpt-4o", stream: true }.to_json) do |req|
      req.options.on_data = proc { |_chunk, _size, _env| }
    end

    expect(events.size).to eq(1)
    expect(events.first.dig(:token_usage, :input_tokens)).to eq(7)
    expect(events.first.dig(:token_usage, :output_tokens)).to eq(2)
    expect(events.first[:stream]).to be true
    expect(events.first[:usage_source]).to eq("stream_final")
    expect(events.first[:provider_response_id]).to eq("chatcmpl_stream_123")
  end

  it "preserves a 1-arg on_data lambda" do
    sse_body = "data: {\"id\":\"chat_1arg\",\"model\":\"gpt-4o\"," \
               "\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n" \
               "data: [DONE]\n\n"
    chunks_received = []
    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") do |env|
          env.request.on_data&.call(sse_body, sse_body.bytesize, env)
          [200, { "Content-Type" => "text/event-stream" }, sse_body]
        end
      end
    end

    conn.post("/v1/chat/completions", { model: "gpt-4o", stream: true }.to_json) do |req|
      req.options.on_data = ->(chunk) { chunks_received << chunk }
    end

    expect(chunks_received).to eq([sse_body])
  end

  it "preserves a 2-arg on_data lambda" do
    sse_body = "data: {\"id\":\"chat_2arg\",\"model\":\"gpt-4o\"," \
               "\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n" \
               "data: [DONE]\n\n"
    received = []
    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") do |env|
          env.request.on_data&.call(sse_body, sse_body.bytesize, env)
          [200, { "Content-Type" => "text/event-stream" }, sse_body]
        end
      end
    end

    conn.post("/v1/chat/completions", { model: "gpt-4o", stream: true }.to_json) do |req|
      req.options.on_data = ->(chunk, size) { received << [chunk, size] }
    end

    expect(received.first[1]).to eq(sse_body.bytesize)
  end

  it "preserves a variadic on_data proc with negative arity" do
    sse_body = "data: {\"id\":\"chat_var\",\"model\":\"gpt-4o\"," \
               "\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n" \
               "data: [DONE]\n\n"
    received = []
    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") do |env|
          env.request.on_data&.call(sse_body, sse_body.bytesize, env)
          [200, { "Content-Type" => "text/event-stream" }, sse_body]
        end
      end
    end

    conn.post("/v1/chat/completions", { model: "gpt-4o", stream: true }.to_json) do |req|
      req.options.on_data = proc { |*args| received << args.length }
    end

    expect(received).not_to be_empty
    expect(received).to all(eq(3))
  end

  it "logs and swallows unexpected post-response errors so the user request returns normally" do
    sse_body = "data: {\"id\":\"chatcmpl_1\",\"model\":\"gpt-4o\"," \
               "\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}\n\n"
    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") do
          [200, { "Content-Type" => "text/event-stream" }, sse_body]
        end
      end
    end

    allow(LlmCostTracker::Tracker).to receive(:record).and_raise(StandardError, "boom")
    expect(LlmCostTracker::Logging).to receive(:warn).with(/boom/).at_least(:once)

    expect { conn.post("/v1/chat/completions", { model: "gpt-4o", stream: true }.to_json) }
      .not_to raise_error
  end

  it "labels an invalid URI by stripping the query string before tagging it on the warning" do
    label = LlmCostTracker::Middleware::Faraday.new(->(_env) { Faraday::Response.new })
      .send(:request_url_label, "ht!tp://broken url[ with ]bad chars?foo=1")
    expect(label).to eq("ht!tp://broken url[ with ]bad chars")
  end

  it "leaves Anthropic streaming bodies untouched because the parser opts out of stream_options injection" do
    sse_body = "event: message_start\n" \
               "data: {\"type\":\"message_start\",\"message\":" \
               "{\"id\":\"msg_x\",\"model\":\"claude-sonnet-4-6\"," \
               "\"usage\":{\"input_tokens\":10,\"output_tokens\":1}}}\n\n" \
               "event: message_delta\ndata: {\"type\":\"message_delta\"," \
               "\"usage\":{\"output_tokens\":7}}\n\n"
    request_body_seen = nil
    conn = Faraday.new(url: "https://api.anthropic.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/v1/messages") do |env|
          request_body_seen = env.request_body
          env.request.on_data&.call(sse_body, sse_body.bytesize, env)
          [200, { "Content-Type" => "text/event-stream" }, sse_body]
        end
      end
    end

    conn.post("/v1/messages", { model: "claude-sonnet-4-6", stream: true }.to_json) do |req|
      req.options.on_data = proc { |_chunk, _size, _env| }
    end

    expect(JSON.parse(request_body_seen)).not_to include("stream_options")
  end

  it "warns only once when the streaming tap overflowed and the response body is also blank" do
    middleware = LlmCostTracker::Middleware::Faraday.new(->(_env) { Faraday::Response.new })
    parser = LlmCostTracker::Providers::Openai::Parser.new
    response_env = double("response_env", body: nil, status: 200, response_headers: {})
    stub_const("LlmCostTracker::Capture::SSE::LIMIT_BYTES", 8)
    stream_buffer = LlmCostTracker::Capture::StreamTap.new
    stream_buffer << "data: {\"id\":\"chatcmpl_overflowing\"}\n\n"
    warnings = []
    allow(LlmCostTracker::Logging).to receive(:warn) { |message| warnings << message }

    middleware.send(
      :parse_stream,
      parser: parser,
      request_url: "https://api.openai.com/v1/chat/completions",
      request_body: { model: "gpt-4o", stream: true }.to_json,
      response_env: response_env,
      stream_buffer: stream_buffer
    )

    expect(warnings.count { |w| w.include?("exceeded") }).to eq(1)
  end

  it "logs and returns nil when the streaming tap cannot be installed" do
    middleware = LlmCostTracker::Middleware::Faraday.new(->(_env) { Faraday::Response.new })
    failing_request = double("request")
    allow(failing_request).to receive(:on_data).and_return(proc { |_| })
    allow(failing_request).to receive(:on_data=).and_raise(StandardError, "cannot rewrap on_data")
    request_env = double("request_env", request: failing_request)

    expect(LlmCostTracker::Logging).to receive(:warn).with(/cannot rewrap on_data/)
    parser = LlmCostTracker::Providers::Openai::Parser.new
    expect(middleware.send(:install_stream_tap, request_env, parser)).to be_nil
  end

  it "re-raises non-streaming adapter errors without emitting an interrupted-stream event" do
    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") { |_env| raise Faraday::ConnectionFailed, "boom" }
      end
    end

    events = []
    ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
      events << payload
    end

    expect do
      conn.post("/v1/chat/completions", { model: "gpt-4o" }.to_json)
    end.to raise_error(Faraday::ConnectionFailed)
    expect(events).to be_empty
  end

  it "logs and continues when interrupted-stream capture itself raises" do
    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") { |_env| raise Faraday::ConnectionFailed, "first" }
      end
    end

    allow(LlmCostTracker::Tracker).to receive(:record).and_raise("recording blew up")

    expect(LlmCostTracker::Logging).to receive(:warn).with(/recording blew up/i).at_least(:once)
    expect do
      conn.post("/v1/chat/completions", { model: "gpt-4o", stream: true }.to_json) do |req|
        req.options.on_data = proc { |_c, _s, _e| }
      end
    end.to raise_error(Faraday::ConnectionFailed)
  end

  it "records an unknown-usage event when the adapter raises mid-stream" do
    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") do |env|
          env.request.on_data&.call("data: {\"model\":\"gpt-4o\"}\n\n", 26, env)
          raise Faraday::ConnectionFailed, "network died mid-stream"
        end
      end
    end

    events = []
    ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
      events << payload
    end

    expect do
      conn.post("/v1/chat/completions", { model: "gpt-4o", stream: true }.to_json) do |req|
        req.options.on_data = proc { |_chunk, _size, _env| }
      end
    end.to raise_error(Faraday::ConnectionFailed)

    expect(events.size).to eq(1)
    expect(events.first[:usage_source]).to eq("unknown")
    expect(events.first[:tags]).to include(stream_interrupted: true)
    expect(events.first[:tags][:stream_interrupted_error]).to include("Faraday::ConnectionFailed")
  end

  it "preserves the provider name when an Anthropic stream is interrupted mid-flight" do
    conn = Faraday.new(url: "https://api.anthropic.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/v1/messages") do |env|
          env.request.on_data&.call("event: message_start\n", 21, env)
          raise Faraday::ConnectionFailed, "network died mid-stream"
        end
      end
    end

    events = []
    ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
      events << payload
    end

    expect do
      conn.post("/v1/messages", { model: "claude-sonnet-4-6", stream: true }.to_json) do |req|
        req.options.on_data = proc { |_chunk, _size, _env| }
      end
    end.to raise_error(Faraday::ConnectionFailed)

    expect(events.size).to eq(1)
    expect(events.first[:provider]).to eq("anthropic")
    expect(events.first[:model]).to eq("claude-sonnet-4-6")
  end

  it "records an unknown-usage event for oversized streaming responses" do
    stub_const("LlmCostTracker::Capture::SSE::LIMIT_BYTES", 32)

    sse_body = "data: " \
               "{\"id\":\"chatcmpl_stream_oversized\",\"model\":\"gpt-4o\"," \
               "\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":2,\"total_tokens\":9}}\n\n"

    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") do |env|
          env.request.on_data&.call(sse_body, sse_body.bytesize, env)
          [200, { "Content-Type" => "text/event-stream" }, ""]
        end
      end
    end

    events = []
    ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
      events << payload
    end

    log = capture_log do
      response = conn.post("/v1/chat/completions", { model: "gpt-4o", stream: true }.to_json) do |req|
        req.options.on_data = proc { |_chunk, _size, _env| }
      end

      expect(response.status).to eq(200)
    end

    expect(log).to match(/exceeded 32 bytes/)

    expect(events.size).to eq(1)
    expect(events.first[:stream]).to be true
    expect(events.first[:usage_source]).to eq("unknown")
    expect(events.first.dig(:token_usage, :input_tokens)).to eq(0)
    expect(events.first.dig(:token_usage, :output_tokens)).to eq(0)
  end

  describe "streams far longer than the capture limit" do
    def stream_through(host, path, body, request:, chunk_size: 4_096)
      conn = Faraday.new(url: host) do |f|
        f.use :llm_cost_tracker
        f.adapter :test do |stub|
          stub.post(path) do |env|
            (0...body.bytesize).step(chunk_size) do |offset|
              chunk = body.byteslice(offset, chunk_size)
              env.request.on_data&.call(chunk, chunk.bytesize, env)
            end
            [200, { "Content-Type" => "text/event-stream" }, ""]
          end
        end
      end

      recorded = []
      subscription = ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
        recorded << payload
      end
      conn.post(path, request.to_json) { |req| req.options.on_data = proc { |_chunk, _size, _env| } }
      recorded
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    end

    def sse(data, event: nil)
      "#{"event: #{event}\n" if event}data: #{data.to_json}\n\n"
    end

    it "records OpenAI chat-completions usage from the final chunk of a 20,000-chunk stream" do
      chunk = { id: "chatcmpl_long", object: "chat.completion.chunk", model: "gpt-4o-2024-08-06",
                choices: [{ index: 0, delta: { content: " token" }, finish_reason: nil }], usage: nil }
      body = +""
      20_000.times { body << sse(chunk) }
      body << sse(chunk.merge(choices: [], usage: { prompt_tokens: 1_200, completion_tokens: 20_000,
                                                    total_tokens: 21_200 }))
      body << "data: [DONE]\n\n"
      expect(body.bytesize).to be > 2 * LlmCostTracker::Capture::SSE::LIMIT_BYTES

      recorded = stream_through("https://api.openai.com", "/v1/chat/completions", body,
                                request: { model: "gpt-4o", stream: true, messages: [] })

      expect(recorded.size).to eq(1)
      expect(recorded.first).to include(usage_source: "stream_final", provider_response_id: "chatcmpl_long",
                                        model: "gpt-4o-2024-08-06")
      expect(recorded.first[:token_usage]).to include(input_tokens: 1_200, output_tokens: 20_000)
    end

    it "keeps a Responses web search call from the middle of a long stream as a billed line item" do
      body = sse({ type: "response.created", response: { id: "resp_long", model: "gpt-4o", output: [] } },
                 event: "response.created")
      delta = { type: "response.output_text.delta", item_id: "msg_1", output_index: 1, content_index: 0,
                delta: " token" }
      10_000.times do |index|
        if index == 5_000
          body << sse({ type: "response.output_item.done", output_index: 0,
                        item: { id: "ws_1", type: "web_search_call", status: "completed" } },
                      event: "response.output_item.done")
        end
        body << sse(delta, event: "response.output_text.delta")
      end
      body << sse({ type: "response.completed",
                    response: { id: "resp_long", model: "gpt-4o", status: "completed",
                                output: [{ id: "msg_1", type: "message", role: "assistant", content: [] }],
                                usage: { input_tokens: 100, output_tokens: 10_000, total_tokens: 10_100 } } },
                  event: "response.completed")

      recorded = stream_through("https://api.openai.com", "/v1/responses", body,
                                request: { model: "gpt-4o", stream: true, input: "hi", tools: [{ type: "web_search" }] })

      expect(recorded.first).to include(usage_source: "stream_final", provider_response_id: "resp_long")
      expect(recorded.first[:token_usage]).to include(input_tokens: 100, output_tokens: 10_000)
      expect(recorded.first[:line_items].map { |item| item[:kind] }).to include("web_search_request")
    end

    it "records Anthropic input usage from message_start and output usage from the final message_delta" do
      body = sse({ type: "message_start",
                   message: { id: "msg_long", type: "message", role: "assistant", model: "claude-sonnet-4-5",
                              usage: { input_tokens: 1_200, cache_read_input_tokens: 300, output_tokens: 1 } } },
                 event: "message_start")
      delta = { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: " token" } }
      20_000.times { body << sse(delta, event: "content_block_delta") }
      body << sse({ type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 20_000 } },
                  event: "message_delta")
      body << sse({ type: "message_stop" }, event: "message_stop")

      recorded = stream_through("https://api.anthropic.com", "/v1/messages", body,
                                request: { model: "claude-sonnet-4-5", stream: true, messages: [] })

      expect(recorded.first).to include(usage_source: "stream_final", provider_response_id: "msg_long")
      expect(recorded.first[:token_usage]).to include(input_tokens: 1_200, cache_read_input_tokens: 300,
                                                      output_tokens: 20_000)
    end

    def gemini_chunks(count, grounded_at:)
      Array.new(count) do |index|
        candidate = { content: { parts: [{ text: " token" }], role: "model" }, index: 0 }
        candidate[:groundingMetadata] = { webSearchQueries: %w[q1 q2] } if index == grounded_at
        { candidates: [candidate], responseId: "gem_long", modelVersion: "gemini-2.5-flash",
          usageMetadata: { promptTokenCount: 50, candidatesTokenCount: index + 1, totalTokenCount: 51 + index } }
      end
    end

    it "keeps Gemini grounding from the middle of a long SSE stream and usage from its last chunk" do
      body = gemini_chunks(8_000, grounded_at: 400).map { |chunk| sse(chunk) }.join

      recorded = stream_through("https://generativelanguage.googleapis.com",
                                "/v1beta/models/gemini-2.5-flash:streamGenerateContent", body,
                                request: { contents: [] })

      expect(recorded.first).to include(usage_source: "stream_final", provider_response_id: "gem_long")
      expect(recorded.first[:token_usage]).to include(input_tokens: 50, output_tokens: 8_000)
      expect(recorded.first[:line_items].map { |item| item[:kind] }).to include("grounding_request")
    end

    it "records usage from a long Gemini stream sent as a JSON array" do
      body = "[#{gemini_chunks(8_000, grounded_at: -1).map(&:to_json).join("\n,\r\n")}]"

      recorded = stream_through("https://generativelanguage.googleapis.com",
                                "/v1beta/models/gemini-2.5-flash:streamGenerateContent", body,
                                request: { contents: [] }, chunk_size: 1_000)

      expect(recorded.first).to include(usage_source: "stream_final", provider_response_id: "gem_long")
      expect(recorded.first[:token_usage]).to include(input_tokens: 50, output_tokens: 8_000)
    end
  end

  it "falls back to reading the response body when the caller set no on_data" do
    sse_body = "data: {\"model\":\"gpt-4o\"}\n\n" \
               "data: {\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":1,\"total_tokens\":5}}\n\n"

    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") do
          [200, { "Content-Type" => "text/event-stream" }, sse_body]
        end
      end
    end

    events = []
    ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
      events << payload
    end

    conn.post("/v1/chat/completions", { model: "gpt-4o", stream: true }.to_json)

    expect(events.size).to eq(1)
    expect(events.first.dig(:token_usage, :input_tokens)).to eq(4)
    expect(events.first[:stream]).to be true
  end

  it "records an unknown-usage streaming event when no usage chunk arrives" do
    sse_body = "data: {\"model\":\"gpt-4o\",\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n" \
               "data: [DONE]\n\n"

    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") do
          [200, { "Content-Type" => "text/event-stream" }, sse_body]
        end
      end
    end

    events = []
    ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
      events << payload
    end

    conn.post("/v1/chat/completions", { model: "gpt-4o", stream: true }.to_json)

    expect(events.first[:stream]).to be true
    expect(events.first[:usage_source]).to eq("unknown")
    expect(events.first.dig(:token_usage, :input_tokens)).to eq(0)
  end

  it "auto-injects stream_options.include_usage on OpenAI chat-completions streaming requests" do
    captured_body = nil

    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") do |env|
          captured_body = env.body
          [200, { "Content-Type" => "text/event-stream" }, ""]
        end
      end
    end

    conn.post("/v1/chat/completions", { model: "gpt-4o", stream: true }.to_json)

    parsed = JSON.parse(captured_body)
    expect(parsed.dig("stream_options", "include_usage")).to be true
  end

  it "preserves an explicit stream_options.include_usage = false set by the caller" do
    captured_body = nil

    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") do |env|
          captured_body = env.body
          [200, { "Content-Type" => "text/event-stream" }, ""]
        end
      end
    end

    conn.post(
      "/v1/chat/completions",
      { model: "gpt-4o", stream: true, stream_options: { include_usage: false } }.to_json
    )

    parsed = JSON.parse(captured_body)
    expect(parsed.dig("stream_options", "include_usage")).to be false
  end

  it "merges include_usage alongside other caller-supplied stream_options" do
    captured_body = nil

    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") do |env|
          captured_body = env.body
          [200, { "Content-Type" => "text/event-stream" }, ""]
        end
      end
    end

    conn.post(
      "/v1/chat/completions",
      { model: "gpt-4o", stream: true, stream_options: { other_flag: true } }.to_json
    )

    parsed = JSON.parse(captured_body)
    expect(parsed["stream_options"]).to eq("other_flag" => true, "include_usage" => true)
  end

  it "does not auto-inject stream_options on non-streaming chat-completions requests" do
    captured_body = nil

    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") do |env|
          captured_body = env.body
          [200, { "Content-Type" => "application/json" }, openai_response_body]
        end
      end
    end

    conn.post("/v1/chat/completions", { model: "gpt-4o" }.to_json)

    expect(JSON.parse(captured_body)).not_to have_key("stream_options")
  end

  it "does not auto-inject stream_options on the Responses API where usage is automatic" do
    captured_body = nil

    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/v1/responses") do |env|
          captured_body = env.body
          [200, { "Content-Type" => "text/event-stream" }, ""]
        end
      end
    end

    conn.post("/v1/responses", { model: "gpt-5-mini", stream: true }.to_json)

    expect(JSON.parse(captured_body)).not_to have_key("stream_options")
  end

  it "skips auto-injection when config.capture.request_stream_usage is false" do
    LlmCostTracker.configure { |config| config.capture.request_stream_usage = false }

    captured_body = nil

    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") do |env|
          captured_body = env.body
          [200, { "Content-Type" => "text/event-stream" }, ""]
        end
      end
    end

    conn.post("/v1/chat/completions", { model: "gpt-4o", stream: true }.to_json)

    expect(JSON.parse(captured_body)).not_to have_key("stream_options")
  end

  it "auto-injects on OpenAI-compatible chat-completions streaming requests (Groq)" do
    captured_body = nil

    conn = Faraday.new(url: "https://api.groq.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/openai/v1/chat/completions") do |env|
          captured_body = env.body
          [200, { "Content-Type" => "text/event-stream" }, ""]
        end
      end
    end

    conn.post(
      "/openai/v1/chat/completions",
      { model: "llama-3.3-70b-versatile", stream: true }.to_json
    )

    parsed = JSON.parse(captured_body)
    expect(parsed.dig("stream_options", "include_usage")).to be true
  end

  describe "stream_options injection on hosts that may reject it" do
    def sent_body(url, body = { model: "gpt-4o", stream: true })
      captured_body = nil
      uri = URI(url)
      conn = Faraday.new(url: "https://#{uri.host}") do |f|
        f.use :llm_cost_tracker
        f.adapter :test do |stub|
          stub.post(uri.path) do |env|
            captured_body = env.body
            [200, { "Content-Type" => "text/event-stream" }, ""]
          end
        end
      end
      conn.post(uri.request_uri, body.to_json)
      JSON.parse(captured_body)
    end

    it "auto-injects on Azure OpenAI only from api-version 2024-06-01 and not with On Your Data" do
      url = "https://myresource.openai.azure.com/openai/deployments/gpt4o-prod/chat/completions?api-version="

      expect(sent_body("#{url}2024-10-21").dig("stream_options", "include_usage")).to be true
      expect(sent_body("#{url}2024-02-01")).not_to have_key("stream_options")
      expect(sent_body("#{url}2024-10-21", { stream: true, data_sources: [] })).not_to have_key("stream_options")
    end

    it "leaves streams to hosts the app added to openai_compatible_providers untouched" do
      LlmCostTracker.configure do |config|
        config.capture.openai_compatible_providers["llm.example.com"] = "internal_gateway"
      end

      expect(sent_body("https://llm.example.com/v1/chat/completions")).not_to have_key("stream_options")
    end
  end

  it "auto-injects when the caller hands Faraday a Hash body" do
    captured_body = nil

    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") do |env|
          captured_body = env.body
          [200, { "Content-Type" => "text/event-stream" }, ""]
        end
      end
    end

    conn.post("/v1/chat/completions", { model: "gpt-4o", stream: true })

    expect(captured_body).to be_a(String)
    parsed = JSON.parse(captured_body)
    expect(parsed.dig("stream_options", "include_usage")).to be true
  end

  it "leaves request bodies that are not JSON untouched" do
    captured_body = nil

    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") do |env|
          captured_body = env.body
          [200, { "Content-Type" => "text/event-stream" }, ""]
        end
      end
    end

    conn.post("/v1/chat/completions", "not json at all")

    expect(captured_body).to eq("not json at all")
  end

  it "can block LLM requests before they hit the adapter" do
    error = LlmCostTracker::BudgetExceededError.new(budget_type: :monthly, total: 1.0, budget: 1.0)
    requests = 0

    allow(LlmCostTracker::Budget).to receive(:enforce!).and_raise(error)

    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") do
          requests += 1
          [200, { "Content-Type" => "application/json" }, openai_response_body]
        end
      end
    end

    expect do
      conn.post("/v1/chat/completions", { model: "gpt-4o" }.to_json)
    end.to raise_error(LlmCostTracker::BudgetExceededError)
    expect(requests).to eq(0)
  end

  it "passes provider, model, and parsed request body to Budget.enforce! for pre-send estimation" do
    allow(LlmCostTracker::Budget).to receive(:enforce!)

    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") do
          [200, { "Content-Type" => "application/json" }, openai_response_body]
        end
      end
    end

    conn.post("/v1/chat/completions", { "model" => "gpt-4o", "messages" => [{ "role" => "user", "content" => "hi" }] }.to_json)

    expect(LlmCostTracker::Budget).to have_received(:enforce!).with(
      provider: "openai",
      model: "gpt-4o",
      request: include("model" => "gpt-4o", "messages" => [{ "role" => "user", "content" => "hi" }])
    )
  end

  it "resolves Gemini's model from the request URL path for pre-send estimation" do
    allow(LlmCostTracker::Budget).to receive(:enforce!)

    conn = Faraday.new(url: "https://generativelanguage.googleapis.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/v1beta/models/gemini-2.0-flash:generateContent") do
          [200, { "Content-Type" => "application/json" }, "{}"]
        end
      end
    end

    conn.post("/v1beta/models/gemini-2.0-flash:generateContent", { "contents" => [] }.to_json)

    expect(LlmCostTracker::Budget).to have_received(:enforce!).with(
      hash_including(provider: "gemini", model: "gemini-2.0-flash")
    )
  end
end
