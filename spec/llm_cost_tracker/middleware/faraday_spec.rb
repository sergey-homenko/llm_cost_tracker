# frozen_string_literal: true

require "spec_helper"
require "faraday"

RSpec.describe LlmCostTracker::Middleware::Faraday do
  let(:openai_response_body) do
    {
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
    expect(events.first[:input_tokens]).to eq(10)
    expect(events.first[:output_tokens]).to eq(5)
    expect(events.first[:cost]).not_to be_nil
    expect(events.first[:latency_ms]).to be_a(Integer)
    expect(events.first[:latency_ms]).to be >= 0
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
    end.to output(/streaming responses are captured automatically/).to_stderr
  end

  it "raises budget errors from post-response enforcement" do
    LlmCostTracker.configure do |config|
      config.monthly_budget = 0.000001
      config.budget_exceeded_behavior = :raise
    end

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
    sse_body = "data: {\"model\":\"gpt-4o\",\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n" \
               "data: {\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":2,\"total_tokens\":9}}\n\n" \
               "data: [DONE]\n\n"

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

    conn.post("/v1/chat/completions", { model: "gpt-4o", stream: true }.to_json) do |req|
      req.options.on_data = proc { |_chunk, _size, _env| }
    end

    expect(events.size).to eq(1)
    expect(events.first[:input_tokens]).to eq(7)
    expect(events.first[:output_tokens]).to eq(2)
    expect(events.first[:stream]).to be true
    expect(events.first[:usage_source]).to eq("stream_final")
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
    expect(events.first[:input_tokens]).to eq(4)
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
    expect(events.first[:input_tokens]).to eq(0)
  end

  it "can block LLM requests before they hit the adapter" do
    error = LlmCostTracker::BudgetExceededError.new(monthly_total: 1.0, budget: 1.0)
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
