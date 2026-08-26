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

  it "shows quarantined async-inbox rows even when no calls are recorded" do
    LlmCostTracker.configuration.ingestion.mode = :async
    LlmCostTracker::Ingestion::InboxEntry.create!(
      event_id: "quarantined-view-1", total_cost: 3.5, tracked_at: Time.utc(2026, 1, 1),
      payload: "{", attempts: LlmCostTracker::Ingestion::InboxEntry::MAX_ATTEMPTS_BEFORE_QUARANTINE
    )

    response = get("/llm-costs/data_quality")

    expect(response.status).to eq(200)
    expect(response.body).to include("Quarantined inbox rows")
    expect(response.body).to include("No data yet")
  end

  it "shows cost, tag, and latency coverage metrics" do
    create_call(provider: "openai", model: "gpt-4o", total_cost: 1.0, latency_ms: 100, tags: { env: "prod" })
    create_call(provider: "openai", model: "unknown-model", total_cost: nil, latency_ms: nil, tags: {})

    response = get("/llm-costs/data_quality")

    expect(response.status).to eq(200)
    expect(response.body).to include("Incomplete pricing by model")
    expect(response.body).to include("unknown-model")
    expect(response.body).to include("Coverage summary")
    expect(response.body).to include("Cost (pricing known)")
    expect(response.body).to include("Tags (at least one tag)")
    expect(response.body).to include("Token usage")
    expect(response.body).to include("Regular input")
    expect(response.body).to include("Data Quality")
  end

  it "shows hidden output share when breakdown columns have output tokens" do
    create_call(output_tokens: 100, hidden_output_tokens: 25)

    response = get("/llm-costs/data_quality")

    expect(response.status).to eq(200)
    expect(response.body).to include("Hidden output share")
    expect(response.body).to include("Hidden output")
    expect(response.body).to include("25.0%")
  end

  it "shows service charge coverage rows" do
    call = create_call(provider: "openai")
    LlmCostTracker::CallLineItem.create!(
      llm_cost_tracker_call_id: call.id,
      position: 0,
      kind: "web_search_request",
      direction: "neither",
      modality: "text",
      cache_state: "none",
      quantity: 2,
      unit: "request",
      rate_quantity: 1000,
      cost: 0.02,
      currency: "USD",
      cost_status: LlmCostTracker::Charges::CostStatus::COMPLETE,
      details: {},
      created_at: Time.now.utc
    )

    response = get("/llm-costs/data_quality")

    expect(response.status).to eq(200)
    expect(response.body).to include("Service charges")
    expect(response.body).to include("web_search_request")
    expect(response.body).to include("complete")
  end

  it "links to unknown pricing calls" do
    create_call(total_cost: nil)
    response = get("/llm-costs/data_quality")

    expect(response.status).to eq(200)
    expect(response.body).to include("unknown_pricing")
  end

  it "rejects oversized data quality ranges as bad requests" do
    response = get("/llm-costs/data_quality?from=2025-01-01&to=2026-04-20")

    expect(response.status).to eq(400)
    expect(response.body).to include("Invalid filter")
    expect(response.body).to include("date range cannot exceed")
  end

  it "renders a setup state when the ledger table is missing" do
    drop_calls_table_with_dependents!
    LlmCostTracker::Call.reset_column_information

    response = get("/llm-costs/data_quality")

    expect(response.status).to eq(200)
    expect(response.body).to include("llm_cost_tracker_calls")
  end

  it "surfaces streaming coverage and a streams-without-usage callout" do
    create_call(stream: true,  usage_source: "stream_final", provider_response_id: "resp_1")
    create_call(stream: true,  usage_source: "unknown")
    create_call(stream: false, usage_source: "response", provider_response_id: "resp_2")

    response = get("/llm-costs/data_quality")

    expect(response.body).to include("Streaming calls")
    expect(response.body).to include("Streams without usage")
    expect(response.body).to include("Streaming usage captured")
    expect(response.body).to include("Calls with provider response ID")
    expect(response.body).to include("Provider response ID")
  end

  it "breaks streaming health down per provider when streams exist" do
    create_call(provider: "openai",     stream: true, usage_source: "stream_final")
    create_call(provider: "openai",     stream: true, usage_source: "stream_final")
    create_call(provider: "openrouter", stream: true, usage_source: "unknown")
    create_call(provider: "openrouter", stream: true, usage_source: "stream_final")

    response = get("/llm-costs/data_quality")

    expect(response.body).to include("Streaming health by provider")
    expect(response.body).to match(%r{<code[^>]*>openai</code>})
    expect(response.body).to match(%r{<code[^>]*>openrouter</code>})
  end

  it "omits the streaming health section when no streams are recorded in the slice" do
    create_call(stream: false, usage_source: "response")

    response = get("/llm-costs/data_quality")

    expect(response.body).not_to include("Streaming health by provider")
  end
  it "names budgeted tags no call has ever carried" do
    LlmCostTracker.configuration.budgets.per_tag = { tenant_id: { monthly: 10 }, ghost: { monthly: 10 } }
    create_call(total_cost: 1.0, tags: { "tenant_id" => "acme" })

    response = get("/llm-costs/data_quality")

    expect(response.status).to eq(200)
    expect(response.body).to include("Budgeted tags never recorded")
    expect(response.body).to include("ghost")
  end

  it "stays silent while nothing has been tagged yet" do
    LlmCostTracker.configuration.budgets.per_tag = { ghost: { monthly: 10 } }

    response = get("/llm-costs/data_quality")

    expect(response.status).to eq(200)
    expect(response.body).not_to include("Budgeted tags never recorded")
  end

  it "drops the section once every budgeted tag has been recorded" do
    LlmCostTracker.configuration.budgets.per_tag = { tenant_id: { monthly: 10 } }
    create_call(total_cost: 1.0, tags: { "tenant_id" => "acme" })

    response = get("/llm-costs/data_quality")

    expect(response.body).not_to include("Budgeted tags never recorded")
  end

end
