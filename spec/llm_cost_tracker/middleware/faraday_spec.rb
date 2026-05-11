# frozen_string_literal: true

require "spec_helper"
require "faraday"

RSpec.describe LlmCostTracker::Middleware::Faraday do
  before do
    allow(LlmCostTracker::Ingestion::Inbox).to receive(:save).and_return(true)
    allow(LlmCostTracker::Ingestion::Inline).to receive(:save).and_return(true)
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

    expect do
      response = conn.post("/v1/chat/completions", { model: "gpt-4o" }.to_json)
      expect(response.status).to eq(200)
    end.to output(/Error resolving request tags: RuntimeError: missing request context/).to_stderr

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

    expect do
      conn.post("/v1/chat/completions", { model: "gpt-4o" }.to_json)
    end.to output(/known streaming responses are captured automatically/).to_stderr
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

    expect do
      conn.post("/v1/chat/completions?api_key=secret-token", { model: "gpt-4o" }.to_json)
    end.to output(
      satisfy do |captured|
        captured.include?("https://api.openai.com/v1/chat/completions;") &&
          !captured.include?("secret-token")
      end
    ).to_stderr
  end

  it "raises budget errors from post-response enforcement" do
    LlmCostTracker.configure do |config|
      config.monthly_budget = 0.000001
      config.budget_exceeded_behavior = :raise
    end
    allow(LlmCostTracker::Ledger::Period::Totals).to receive(:call).and_return(month: 0.000075)

    expect do
      connection.post("/v1/chat/completions", { model: "gpt-4o" }.to_json)
    end.to raise_error(LlmCostTracker::BudgetExceededError)
  end

  it "raises unknown pricing errors from post-response enforcement" do
    LlmCostTracker.configure do |config|
      config.unknown_pricing_behavior = :raise
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
    expect(events.first[:usage_source]).to eq(:stream_final)
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

  it "records an unknown-usage event for oversized streaming responses" do
    stub_const("LlmCostTracker::Capture::Stream::LIMIT_BYTES", 32)

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

    expect do
      response = conn.post("/v1/chat/completions", { model: "gpt-4o", stream: true }.to_json) do |req|
        req.options.on_data = proc { |_chunk, _size, _env| }
      end

      expect(response.status).to eq(200)
    end.to output(/exceeded 32 bytes/).to_stderr

    expect(events.size).to eq(1)
    expect(events.first[:stream]).to be true
    expect(events.first[:usage_source]).to eq(:unknown)
    expect(events.first.dig(:token_usage, :input_tokens)).to eq(0)
    expect(events.first.dig(:token_usage, :output_tokens)).to eq(0)
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
    expect(events.first[:usage_source]).to eq(:unknown)
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

  it "skips auto-injection when config.auto_enable_stream_usage is false" do
    LlmCostTracker.configure { |config| config.auto_enable_stream_usage = false }

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

    allow(LlmCostTracker::Tracker).to receive(:enforce_budget!).and_raise(error)

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
end
