# frozen_string_literal: true

require "spec_helper"

ENV["RAILS_ENV"] ||= "test"

require_relative "../../dummy/config/environment"

RSpec.describe "LlmCostTracker::Engine overview" do
  include_context "with mounted llm cost tracker engine"

  it "renders the mounted dashboard with an empty state" do
    response = get("/llm-costs")

    expect(response.status).to eq(200)
    expect(response.body).to include("LLM Cost Tracker")
    expect(response.body).to include("No LLM calls yet")
  end

  it "renders overview stats, daily spend, top models, and budget status" do
    LlmCostTracker.configure do |config|
      config.storage_backend = :active_record
      config.monthly_budget = 10.0
    end

    create_call(
      provider: "openai",
      model: "gpt-4o",
      total_cost: 2.0,
      latency_ms: 100,
      tags: { feature: "chat" },
      tracked_at: Time.now.utc
    )
    create_call(
      provider: "anthropic",
      model: "claude-haiku-4-5",
      total_cost: 3.0,
      latency_ms: 300,
      tags: { feature: "summarizer" },
      tracked_at: 1.day.ago
    )

    response = get("/llm-costs")

    expect(response.status).to eq(200)
    expect(response.body).to include("Total spend")
    expect(response.body).to include("$5.00")
    expect(response.body).to include("Avg latency")
    expect(response.body).to include("200ms")
    expect(response.body).to include("Monthly Budget")
    expect(response.body).to include("Current-month spend across")
    expect(response.body).to include("Soft limit: blocking is not atomic under concurrency.")
    expect(response.body).to include("Daily Spend")
    expect(response.body).to include("Top Models")
    expect(response.body).to include("By Provider")
    expect(response.body).to include("gpt-4o")
    expect(response.body).to include("/llm-costs/calls?model=gpt-4o&amp;provider=openai")
    expect(response.body).to include("/llm-costs/calls?provider=anthropic")
    expect(response.body).not_to include("Cost By Feature")
  end

  it "renders delta badges for cost and calls" do
    create_call(total_cost: 5.0, tracked_at: Time.now.utc)

    response = get("/llm-costs")

    expect(response.status).to eq(200)
    expect(response.body).to include("vs. prior")
  end

  it "applies overview filters to stats and top models" do
    create_call(
      provider: "openai",
      model: "gpt-4o",
      total_cost: 2.0,
      tags: { feature: "chat" },
      tracked_at: Time.now.utc
    )
    create_call(
      provider: "anthropic",
      model: "claude-haiku-4-5",
      total_cost: 3.0,
      tags: { feature: "summarizer" },
      tracked_at: Time.now.utc
    )

    response = get("/llm-costs?provider=openai")

    expect(response.status).to eq(200)
    expect(response.body).to include("$2.00")
    expect(response.body).not_to include("$5.00")
    expect(response.body).to include("gpt-4o")
    expect(response.body).not_to include("claude-haiku-4-5")
  end

  it "renders provider and model dropdown filters" do
    create_call(provider: "openai", model: "gpt-4o", tracked_at: Time.now.utc)
    create_call(provider: "anthropic", model: "claude-haiku-4-5", tracked_at: Time.now.utc)

    response = get("/llm-costs?provider=openai")
    provider_select = response.body
                              .match(%r{<select name="provider" id="lct-overview-provider">(.*?)</select>}m)
                              &.captures
                              &.first
    model_select = response.body
                           .match(%r{<select name="model" id="lct-overview-model">(.*?)</select>}m)
                           &.captures
                           &.first

    expect(response.status).to eq(200)
    expect(provider_select).to include('<option selected="selected" value="openai">openai</option>')
    expect(provider_select).to include('<option value="anthropic">anthropic</option>')
    expect(model_select).to include('<option value="gpt-4o">gpt-4o</option>')
    expect(model_select).not_to include("claude-haiku-4-5")
  end

  it "renders invalid filter errors as bad requests" do
    response = get("/llm-costs?tag[%3BDROP]=x")

    expect(response.status).to eq(400)
    expect(response.body).to include("Invalid filter")
    expect(response.body).to include("invalid tag key")
  end

  it "renders a setup state when the ledger table is missing" do
    ActiveRecord::Base.connection.drop_table(:llm_api_calls)
    LlmCostTracker::LlmApiCall.reset_column_information

    response = get("/llm-costs")

    expect(response.status).to eq(200)
    expect(response.body).to include("llm_api_calls")
    expect(response.body).to include("rails generate llm_cost_tracker:install")
  end
end
