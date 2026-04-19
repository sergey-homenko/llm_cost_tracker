# frozen_string_literal: true

require "spec_helper"

ENV["RAILS_ENV"] ||= "test"

require_relative "../../dummy/config/environment"

RSpec.describe "LlmCostTracker::Engine data quality" do
  include_context "with mounted llm cost tracker engine"

  it "renders an empty state when there are no calls" do
    response = get("/llm-costs/data_quality")

    expect(response.status).to eq(200)
    expect(response.body).to include("No data yet")
  end

  it "shows cost, tag, and latency coverage metrics" do
    create_call(provider: "openai", model: "gpt-4o", total_cost: 1.0, latency_ms: 100, tags: { env: "prod" })
    create_call(provider: "openai", model: "unknown-model", total_cost: nil, latency_ms: nil, tags: {})

    response = get("/llm-costs/data_quality")

    expect(response.status).to eq(200)
    expect(response.body).to include("Unknown Pricing by Model")
    expect(response.body).to include("unknown-model")
    expect(response.body).to include("Coverage Summary")
    expect(response.body).to include("Cost (pricing known)")
    expect(response.body).to include("Tags (at least one tag)")
    expect(response.body).to include("Data Quality")
  end

  it "links to unknown pricing calls" do
    create_call(total_cost: nil)
    response = get("/llm-costs/data_quality")

    expect(response.status).to eq(200)
    expect(response.body).to include("unknown_pricing")
  end

  it "renders a setup state when the ledger table is missing" do
    ActiveRecord::Base.connection.drop_table(:llm_api_calls)
    LlmCostTracker::LlmApiCall.reset_column_information

    response = get("/llm-costs/data_quality")

    expect(response.status).to eq(200)
    expect(response.body).to include("llm_api_calls")
  end
end
