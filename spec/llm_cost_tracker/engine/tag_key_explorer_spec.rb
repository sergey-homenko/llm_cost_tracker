# frozen_string_literal: true

require "spec_helper"

ENV["RAILS_ENV"] ||= "test"

require_relative "../../dummy/config/environment"

RSpec.describe "LlmCostTracker::Engine tag key explorer" do
  include_context "with mounted llm cost tracker engine"

  it "renders an empty state when no tagged calls exist" do
    create_call(tags: {})

    response = get("/llm-costs/tags")

    expect(response.status).to eq(200)
    expect(response.body).to include("No tag keys found")
  end

  it "renders tag keys discovered from call data" do
    create_call(tags: { env: "prod", feature: "chat" })
    create_call(tags: { env: "staging" })
    create_call(tags: { feature: "summarizer" })

    response = get("/llm-costs/tags")

    expect(response.status).to eq(200)
    # SQLite supports tag key discovery
    expect(response.body).to include("env")
    expect(response.body).to include("feature")
    expect(response.body).to include("Breakdown")
  end

  it "links to the tag value breakdown page" do
    create_call(tags: { env: "prod" })

    response = get("/llm-costs/tags")

    expect(response.status).to eq(200)
    expect(response.body).to include("/llm-costs/tags/env")
  end

  it "rejects oversized tag key ranges as bad requests" do
    response = get("/llm-costs/tags?from=2025-01-01&to=2026-04-20")

    expect(response.status).to eq(400)
    expect(response.body).to include("Invalid filter")
    expect(response.body).to include("date range cannot exceed")
  end

  it "renders a setup state when the ledger table is missing" do
    ActiveRecord::Base.connection.drop_table(:llm_api_calls)
    LlmCostTracker::LlmApiCall.reset_column_information

    response = get("/llm-costs/tags")

    expect(response.status).to eq(200)
    expect(response.body).to include("llm_api_calls")
  end
end
