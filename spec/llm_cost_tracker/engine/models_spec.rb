# frozen_string_literal: true

require "spec_helper"

ENV["RAILS_ENV"] ||= "test"

require_relative "../../dummy/config/environment"

RSpec.describe "LlmCostTracker::Engine models" do
  include_context "with mounted llm cost tracker engine"

  it "renders an empty state when no calls match" do
    response = get("/llm-costs/models")

    expect(response.status).to eq(200)
    expect(response.body).to include("Models")
    expect(response.body).to include("No models")
  end

  it "renders models aggregated by provider and model, sorted by total cost" do
    create_call(provider: "openai", model: "gpt-4o",
                input_tokens: 100, output_tokens: 50, total_cost: 1.5, latency_ms: 200)
    create_call(provider: "openai", model: "gpt-4o",
                input_tokens: 200, output_tokens: 100, total_cost: 2.5, latency_ms: 300)
    create_call(provider: "anthropic", model: "claude-haiku-4-5",
                input_tokens: 10, output_tokens: 5, total_cost: 0.5, latency_ms: 100)

    response = get("/llm-costs/models")

    expect(response.status).to eq(200)
    expect(response.body).to include("gpt-4o")
    expect(response.body).to include("claude-haiku-4-5")
    expect(response.body).to include("openai")
    expect(response.body).to include("anthropic")
    expect(response.body).to include("$4.00")
    expect(response.body).to include("$2.00")
    expect(response.body).to include("$0.50")
    expect(response.body).to include("250ms")
    expect(response.body).to include("300")
    expect(response.body).to include("150")
    expect(response.body.index("gpt-4o")).to be < response.body.index("claude-haiku-4-5")
  end

  it "applies provider and model filters" do
    create_call(provider: "openai", model: "gpt-4o", total_cost: 2.0)
    create_call(provider: "anthropic", model: "claude-haiku-4-5", total_cost: 3.0)

    response = get("/llm-costs/models?provider=openai")

    expect(response.status).to eq(200)
    expect(response.body).to include("gpt-4o")
    expect(response.body).not_to include("claude-haiku-4-5")
  end

  it "renders a setup state when the ledger table is missing" do
    ActiveRecord::Base.connection.drop_table(:llm_api_calls)
    LlmCostTracker::LlmApiCall.reset_column_information

    response = get("/llm-costs/models")

    expect(response.status).to eq(200)
    expect(response.body).to include("llm_api_calls")
    expect(response.body).to include("rails generate llm_cost_tracker:install")
  end
end
