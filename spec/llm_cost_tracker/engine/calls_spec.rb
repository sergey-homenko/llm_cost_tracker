# frozen_string_literal: true

require "spec_helper"

ENV["RAILS_ENV"] ||= "test"

require_relative "../../dummy/config/environment"

RSpec.describe "LlmCostTracker::Engine calls" do
  include_context "with mounted llm cost tracker engine"

  it "renders the calls index with cost, token, latency, and tag columns" do
    create_call(
      provider: "openai",
      model: "gpt-4o",
      input_tokens: 1_200,
      output_tokens: 300,
      total_cost: 2.5,
      latency_ms: 250,
      tags: { feature: "chat", user_id: 42 },
      tracked_at: Time.utc(2026, 4, 18, 12, 0, 0)
    )

    response = get("/llm-costs/calls")

    expect(response.status).to eq(200)
    expect(response.body).to include("Calls")
    expect(response.body).to include("gpt-4o")
    expect(response.body).to include("1,200")
    expect(response.body).to include("300")
    expect(response.body).to include("1,500")
    expect(response.body).to include("$2.50")
    expect(response.body).to include("250ms")
    expect(response.body).to include("feature=chat")
    expect(response.body).to include("user_id=42")
    expect(response.body).to include("Details")
    expect(response.body).to include("/llm-costs/calls/#{LlmCostTracker::LlmApiCall.first.id}")
  end

  it "truncates long tag values in call list chips" do
    long_value = "x" * 700
    create_call(tags: { feature: long_value })

    response = get("/llm-costs/calls")

    expect(response.status).to eq(200)
    expect(response.body).to include("feature=#{'x' * 80}...")
    expect(response.body).not_to include("feature=#{long_value}")
    expect(response.body).not_to include(long_value)
  end

  it "filters calls and paginates newest first" do
    create_call(
      provider: "openai",
      model: "new-chat",
      total_cost: 2.0,
      tags: { feature: "chat" },
      tracked_at: Time.utc(2026, 4, 18, 12, 0, 0)
    )
    create_call(
      provider: "openai",
      model: "old-chat",
      total_cost: 1.0,
      tags: { feature: "chat" },
      tracked_at: Time.utc(2026, 4, 18, 11, 0, 0)
    )
    create_call(
      provider: "anthropic",
      model: "claude-haiku-4-5",
      total_cost: 3.0,
      tags: { feature: "summarizer" },
      tracked_at: Time.utc(2026, 4, 18, 12, 0, 0)
    )

    response = get("/llm-costs/calls?provider=openai&tag%5Bfeature%5D=chat&per=1")
    rows = response.body.scan(%r{<td><code class="lct-code">([^<]+)</code></td>}).flatten

    expect(response.status).to eq(200)
    expect(rows).to eq(["new-chat"])
    expect(response.body).to include("Showing <strong>1</strong> to <strong>1</strong> of <strong>2</strong> results")
    expect(response.body).to include("Next")

    second_page = get("/llm-costs/calls?provider=openai&tag%5Bfeature%5D=chat&per=1&page=2")
    second_rows = second_page.body.scan(%r{<td><code class="lct-code">([^<]+)</code></td>}).flatten

    expect(second_page.status).to eq(200)
    expect(second_rows).to eq(["old-chat"])
    expect(second_page.body).to include("Previous")
  end

  it "supports tag hash filters on the calls index" do
    create_call(model: "chat-model", tags: { feature: "chat" })
    create_call(model: "summary-model", tags: { feature: "summarizer" })

    response = get("/llm-costs/calls?tag%5Bfeature%5D=summarizer")

    expect(response.status).to eq(200)
    expect(response.body).to include("summary-model")
    expect(response.body).not_to include("chat-model")
  end

  it "renders provider and model dropdown filters" do
    create_call(provider: "openai", model: "gpt-4o")
    create_call(provider: "anthropic", model: "claude-haiku-4-5")

    response = get("/llm-costs/calls?provider=openai")
    provider_select = response.body
                              .match(%r{<select name="provider" id="lct-provider">(.*?)</select>}m)
                              &.captures
                              &.first
    model_select = response.body
                           .match(%r{<select name="model" id="lct-model">(.*?)</select>}m)
                           &.captures
                           &.first

    expect(response.status).to eq(200)
    expect(provider_select).to include('<option selected="selected" value="openai">openai</option>')
    expect(provider_select).to include('<option value="anthropic">anthropic</option>')
    expect(model_select).to include('<option value="gpt-4o">gpt-4o</option>')
    expect(model_select).not_to include("claude-haiku-4-5")
  end

  it "sorts calls by total cost with unknown pricing last" do
    create_call(model: "mid-cost", total_cost: 2.0, tracked_at: Time.utc(2026, 4, 18, 11, 0, 0))
    create_call(model: "high-cost", total_cost: 5.0, tracked_at: Time.utc(2026, 4, 18, 12, 0, 0))
    create_call(model: "unknown-cost", total_cost: nil, tracked_at: Time.utc(2026, 4, 18, 13, 0, 0))

    response = get("/llm-costs/calls?sort=expensive")

    expect(response.status).to eq(200)
    expect(response.body.index("high-cost")).to be < response.body.index("mid-cost")
    expect(response.body.index("mid-cost")).to be < response.body.index("unknown-cost")
  end

  it "sorts calls by latency with missing latency last" do
    create_call(model: "fast-call", latency_ms: 100, tracked_at: Time.utc(2026, 4, 18, 11, 0, 0))
    create_call(model: "slow-call", latency_ms: 500, tracked_at: Time.utc(2026, 4, 18, 12, 0, 0))
    create_call(model: "unknown-latency", latency_ms: nil, tracked_at: Time.utc(2026, 4, 18, 13, 0, 0))

    response = get("/llm-costs/calls?sort=slow")
    rows = response.body.scan(%r{<td><code class="lct-code">([^<]+)</code></td>}).flatten

    expect(response.status).to eq(200)
    expect(rows).to eq(%w[slow-call fast-call unknown-latency])
  end

  it "renders an empty calls state when filters match nothing" do
    create_call(model: "gpt-4o", tags: { feature: "chat" })

    response = get("/llm-costs/calls?model=missing")

    expect(response.status).to eq(200)
    expect(response.body).to include("No matching calls")
    expect(response.body).not_to include("Matching calls")
  end

  it "renders invalid calls filters as bad requests" do
    response = get("/llm-costs/calls?tag%5B%3BDROP%5D=x")

    expect(response.status).to eq(400)
    expect(response.body).to include("Invalid filter")
    expect(response.body).to include("invalid tag key")
  end

  it "rejects oversized calls ranges as bad requests" do
    response = get("/llm-costs/calls?from=2025-01-01&to=2026-04-20")

    expect(response.status).to eq(400)
    expect(response.body).to include("Invalid filter")
    expect(response.body).to include("date range cannot exceed")
  end

  it "rejects one-sided calls ranges as bad requests" do
    response = get("/llm-costs/calls?from=2026-04-18")

    expect(response.status).to eq(400)
    expect(response.body).to include("Invalid filter")
    expect(response.body).to include("from and to dates")
  end

  it "renders call details with token, cost, latency, pricing, and tags data" do
    call = create_call(
      provider: "openai",
      model: "gpt-4o",
      input_tokens: 1_200,
      output_tokens: 300,
      input_cost: 1.25,
      output_cost: 1.75,
      total_cost: 3.0,
      latency_ms: 250,
      provider_response_id: "chatcmpl_show_123",
      tags: { feature: "chat", user_id: 42 },
      tracked_at: Time.utc(2026, 4, 18, 12, 0, 0)
    )

    response = get("/llm-costs/calls/#{call.id}")

    expect(response.status).to eq(200)
    expect(response.body).to include("Call ##{call.id}")
    expect(response.body).to include("2026-04-18 12:00")
    expect(response.body).to include("openai")
    expect(response.body).to include("gpt-4o")
    expect(response.body).to include("Estimated")
    expect(response.body).to include("Provider Response ID")
    expect(response.body).to include("chatcmpl_show_123")
    expect(response.body).to include("1,200")
    expect(response.body).to include("300")
    expect(response.body).to include("1,500")
    expect(response.body).to include("$1.25")
    expect(response.body).to include("$1.75")
    expect(response.body).to include("$3.00")
    expect(response.body).to include("250ms")
    expect(response.body).to include("Token Mix")
    expect(response.body).to include("Cost Mix")
    expect(response.body).to include("80.0%")
    expect(response.body).to include("20.0%")
    expect(response.body).to include("Tags")
    expect(response.body).to include("feature")
    expect(response.body).to include("chat")
    expect(response.body).to include("Back to calls")
  end

  it "marks call details with nil total cost as unknown pricing" do
    call = create_call(total_cost: nil)

    response = get("/llm-costs/calls/#{call.id}")

    expect(response.status).to eq(200)
    expect(response.body).to include("Unknown pricing")
    expect(response.body).to include("n/a")
    expect(response.body).to include("Pricing not available for this call.")
  end

  it "renders optional metadata on call details when the column exists" do
    ActiveRecord::Base.connection.add_column :llm_api_calls, :metadata, :text
    LlmCostTracker::LlmApiCall.reset_column_information
    call = create_call
    call.update!(metadata: { request_id: "req_123" }.to_json)

    response = get("/llm-costs/calls/#{call.id}")

    expect(response.status).to eq(200)
    expect(response.body).to include("Metadata")
    expect(response.body).to include("request_id")
    expect(response.body).to include("req_123")
  end

  it "includes provider_response_id in CSV exports when the column exists" do
    create_call(provider_response_id: "chatcmpl_csv_123")

    response = get("/llm-costs/calls.csv")

    expect(response.status).to eq(200)
    expect(response.body).to include("provider_response_id")
    expect(response.body).to include("chatcmpl_csv_123")
  end

  it "renders a friendly not-found page for missing call details" do
    response = get("/llm-costs/calls/999")

    expect(response.status).to eq(404)
    expect(response.body).to include("Call not found")
    expect(response.body).to include("Back to calls")
  end

  it "does not route non-numeric call detail ids" do
    response = get("/llm-costs/calls/not-a-number")

    expect(response.status).to eq(404)
  end

  it "renders a calls setup state when the ledger table is missing" do
    ActiveRecord::Base.connection.drop_table(:llm_api_calls)
    LlmCostTracker::LlmApiCall.reset_column_information

    response = get("/llm-costs/calls")

    expect(response.status).to eq(200)
    expect(response.body).to include("llm_api_calls")
    expect(response.body).to include("rails generate llm_cost_tracker:install")
  end

  it "renders a database error when the database is unavailable" do
    allow(LlmCostTracker::LlmApiCall).to receive(:table_exists?)
      .and_raise(ActiveRecord::ConnectionNotEstablished, "database unavailable")

    response = get("/llm-costs/calls")

    expect(response.status).to eq(500)
    expect(response.body).to include("Database unavailable")
  end

  it "renders a call details setup state when the ledger table is missing" do
    ActiveRecord::Base.connection.drop_table(:llm_api_calls)
    LlmCostTracker::LlmApiCall.reset_column_information

    response = get("/llm-costs/calls/1")

    expect(response.status).to eq(200)
    expect(response.body).to include("llm_api_calls")
    expect(response.body).to include("rails generate llm_cost_tracker:install")
  end

  it "exports filtered calls as CSV" do
    create_call(
      provider: "openai",
      model: "gpt-4o",
      input_tokens: 100,
      output_tokens: 50,
      total_cost: 1.25,
      latency_ms: 200,
      tags: { feature: "chat" },
      tracked_at: Time.utc(2026, 4, 18, 12, 0, 0)
    )
    create_call(
      provider: "anthropic",
      model: "claude-haiku-4-5",
      total_cost: 0.5,
      tags: { feature: "summarizer" },
      tracked_at: Time.utc(2026, 4, 18, 13, 0, 0)
    )

    response = get("/llm-costs/calls.csv?provider=openai")

    expect(response.status).to eq(200)
    expect(response.headers["Content-Type"]).to include("text/csv")
    expect(response.headers["Content-Disposition"]).to include("attachment")
    expect(response.headers["Content-Disposition"]).to include(".csv")

    lines = response.body.lines
    expect(lines.first).to include("tracked_at", "provider", "model", "total_cost", "tags")
    expect(response.body).to include("openai")
    expect(response.body).to include("gpt-4o")
    expect(response.body).to include("1.25")
    expect(response.body).not_to include("claude-haiku-4-5")
  end

  it "prefixes CSV values that look like spreadsheet formulas" do
    create_call(
      provider: "openai",
      model: " \t=CMD('/bin/sh')",
      total_cost: 0.1,
      tags: { feature: "chat" },
      tracked_at: Time.utc(2026, 4, 18, 12, 0, 0)
    )

    response = get("/llm-costs/calls.csv")

    expect(response.status).to eq(200)
    expect(response.body).to include("' \t=CMD('/bin/sh')")
  end

  it "exports invalid stored tags as empty JSON" do
    call = create_call(tags: { feature: "chat" })
    call.update_column(:tags, "{")

    response = get("/llm-costs/calls.csv")

    expect(response.status).to eq(200)
    expect(response.body).to include("{}")
  end
end
