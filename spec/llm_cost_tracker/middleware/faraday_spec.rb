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
    expect(events.first[:tags]).to include(feature: "test")
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
end
