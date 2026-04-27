# frozen_string_literal: true

require "spec_helper"

ENV["RAILS_ENV"] ||= "test"

require_relative "../../dummy/config/environment"

RSpec.describe "LlmCostTracker::Engine tags" do
  include_context "with mounted llm cost tracker engine"

  it "renders an empty state when no calls carry the tag" do
    create_call(tags: { other_key: "x" })

    response = get("/llm-costs/tags/feature")

    expect(response.status).to eq(200)
    expect(response.body).to include("feature")
    expect(response.body).to include("No calls tagged with feature")
    expect(response.body).not_to include("other_key")
  end

  it "aggregates calls by tag value, sorted by total cost descending" do
    create_call(total_cost: 2.0, tags: { feature: "chat" })
    create_call(total_cost: 3.0, tags: { feature: "chat" })
    create_call(total_cost: 1.0, tags: { feature: "summarizer" })
    create_call(total_cost: 0.5, tags: { other_key: "x" })

    response = get("/llm-costs/tags/feature")

    expect(response.status).to eq(200)
    expect(response.body).to include("feature")
    expect(response.body).to include("chat")
    expect(response.body).to include("summarizer")
    expect(response.body).to include("$5.00")
    expect(response.body).to include("$2.50")
    expect(response.body).to include("$1.00")
    expect(response.body).to include("/llm-costs/calls?tag%5Bfeature%5D=chat")
    expect(response.body).not_to include("other_key")
    expect(response.body.index("chat")).to be < response.body.index("summarizer")
  end

  it "applies provider and date filters to the tag breakdown" do
    create_call(provider: "openai", total_cost: 2.0, tags: { feature: "chat" })
    create_call(provider: "anthropic", total_cost: 3.0, tags: { feature: "summarizer" })

    response = get("/llm-costs/tags/feature?provider=openai")

    expect(response.status).to eq(200)
    expect(response.body).to include("chat")
    expect(response.body).not_to include("summarizer")
  end

  it "renders invalid tag keys as bad requests" do
    response = get("/llm-costs/tags/%3BDROP")

    expect(response.status).to eq(400)
    expect(response.body).to include("Invalid filter")
    expect(response.body).to include("invalid tag key")
  end

  it "rejects oversized tag value ranges as bad requests" do
    response = get("/llm-costs/tags/feature?from=2025-01-01&to=2026-04-20")

    expect(response.status).to eq(400)
    expect(response.body).to include("Invalid filter")
    expect(response.body).to include("date range cannot exceed")
  end

  it "renders a setup state when the ledger table is missing" do
    ActiveRecord::Base.connection.drop_table(:llm_api_calls)
    LlmCostTracker::LlmApiCall.reset_column_information

    response = get("/llm-costs/tags/feature")

    expect(response.status).to eq(200)
    expect(response.body).to include("llm_api_calls")
    expect(response.body).to include("rails generate llm_cost_tracker:install")
  end
end
