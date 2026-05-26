# frozen_string_literal: true

require "spec_helper"
require "faraday"

require_relative "../../dummy/config/environment"

RSpec.describe LlmCostTracker::Middleware::Faraday do
  include_context "with mounted llm cost tracker engine"

  let(:openai_response_body) do
    {
      id: "chatcmpl_real_storage",
      model: "gpt-4o",
      choices: [{ message: { content: "Hello!" } }],
      usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
    }.to_json
  end

  let(:connection) do
    Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker, tags: { feature: "real-storage" }
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") do
          [200, { "Content-Type" => "application/json" }, openai_response_body]
        end
      end
    end
  end

  it "writes the captured event through the real inbox to the calls ledger" do
    allow(LlmCostTracker::Ingestion::Worker).to receive(:ensure_started)

    connection.post("/v1/chat/completions", { model: "gpt-4o" }.to_json)

    expect(LlmCostTracker::Ingestion::InboxEntry.count).to eq(1)
    expect(LlmCostTracker::Call.count).to eq(0)

    expect(LlmCostTracker::Ingestion::Worker.flush!).to be true

    call = LlmCostTracker::Call.first
    expect(call.provider).to eq("openai")
    expect(call.model).to eq("gpt-4o")
    expect(call.input_tokens).to eq(10)
    expect(call.output_tokens).to eq(5)
    expect(call.total_cost).not_to be_nil
    expect(call.tag_pairs).to include("feature" => "real-storage")
    expect(LlmCostTracker::Ingestion::InboxEntry.count).to eq(0)
  end
end
