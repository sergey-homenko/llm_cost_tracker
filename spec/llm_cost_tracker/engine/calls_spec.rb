# frozen_string_literal: true

require "spec_helper"

ENV["RAILS_ENV"] ||= "test"

require_relative "../../dummy/config/environment"

RSpec.describe "LlmCostTracker::Engine calls" do
  include_context "with mounted llm cost tracker engine"

  around { |example| travel_to(Time.utc(2026, 4, 19, 12)) { example.run } }

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
    expect(response.body).to include("$2.50")
    expect(response.body).to include("250ms")
    expect(response.body).to include(">feature</span>=chat")
    expect(response.body).to include(">user_id</span>=42")
    expect(response.body).to include("Details")
    expect(response.body).to include("/llm-costs/calls/#{LlmCostTracker::Call.first.id}")
  end

  it "truncates long tag values in call list chips" do
    long_value = "x" * 700
    create_call(tags: { feature: long_value })

    response = get("/llm-costs/calls")

    expect(response.status).to eq(200)
    expect(response.body).to include(">feature</span>=#{'x' * 80}...")
    expect(response.body).not_to include("=#{long_value}")
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
    rows = response.body.scan(%r{<td><code class="lct-code-id">([^<]+)</code></td>}).flatten

    expect(response.status).to eq(200)
    expect(rows).to eq(["new-chat"])
    expect(response.body).to include("Showing <strong>1</strong>–<strong>1</strong> of <strong>2</strong>")
    expect(response.body).to include('rel="next"')

    second_page = get("/llm-costs/calls?provider=openai&tag%5Bfeature%5D=chat&per=1&page=2")
    second_rows = second_page.body.scan(%r{<td><code class="lct-code-id">([^<]+)</code></td>}).flatten

    expect(second_page.status).to eq(200)
    expect(second_rows).to eq(["old-chat"])
    expect(second_page.body).to include('rel="prev"')
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
                              .match(%r{<select name="provider" id="lct-filter-provider">(.*?)</select>}m)
                              &.captures
                              &.first
    model_select = response.body
                           .match(%r{<select name="model" id="lct-filter-model">(.*?)</select>}m)
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

    response = get("/llm-costs/calls?sort=cost&dir=desc")
    rows = response.body.scan(%r{<td><code class="lct-code-id">([^<]+)</code></td>}).flatten

    expect(response.status).to eq(200)
    expect(rows).to eq(%w[high-cost mid-cost unknown-cost])
  end

  it "sorts calls by latency with missing latency last" do
    create_call(model: "fast-call", latency_ms: 100, tracked_at: Time.utc(2026, 4, 18, 11, 0, 0))
    create_call(model: "slow-call", latency_ms: 500, tracked_at: Time.utc(2026, 4, 18, 12, 0, 0))
    create_call(model: "unknown-latency", latency_ms: nil, tracked_at: Time.utc(2026, 4, 18, 13, 0, 0))

    response = get("/llm-costs/calls?sort=latency&dir=desc")
    rows = response.body.scan(%r{<td><code class="lct-code-id">([^<]+)</code></td>}).flatten

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
      total_cost: 3.0,
      latency_ms: 250,
      provider_response_id: "chatcmpl_show_123",
      provider_project_id: "proj_show_123",
      provider_api_key_id: "key_show_123",
      provider_workspace_id: "workspace_show_123",
      batch: true,
      tags: { feature: "chat", user_id: 42 },
      tracked_at: Time.utc(2026, 4, 18, 12, 0, 0)
    )

    response = get("/llm-costs/calls/#{call.id}")

    expect(response.status).to eq(200)
    expect(response.body).to include("##{call.id}")
    expect(response.body).to include("2026-04-18 12:00")
    expect(response.body).to include("openai")
    expect(response.body).to include("gpt-4o")
    expect(response.body).to include("Estimated")
    expect(response.body).to include("Response ID")
    expect(response.body).to include("chatcmpl_show_123")
    expect(response.body).to include("Project ID")
    expect(response.body).not_to include("proj_show_123")
    expect(response.body).to include("API Key ID")
    expect(response.body).not_to include("key_show_123")
    expect(response.body).to include("***_123")
    expect(response.body).to include("Workspace ID")
    expect(response.body).not_to include("workspace_show_123")
    expect(response.body).to include("Batch")
    expect(response.body).to include("yes")
    expect(response.body).to include("1,200")
    expect(response.body).to include("300")
    expect(response.body).to include("1,500")
    expect(response.body).to include("$3.00")
    expect(response.body).to match(/250<span class="lct-stat-unit">ms<\/span>/)
    expect(response.body).to include("Token mix")
    expect(response.body).to include("Cost mix")
    expect(response.body).to include("80.0%")
    expect(response.body).to include("20.0%")
    expect(response.body).to include("Tags")
    expect(response.body).to include("feature")
    expect(response.body).to include("chat")
    expect(response.body).to include("lct-breadcrumb-back")
  end

  it "marks call details with nil total cost as unknown pricing" do
    call = create_call(
      total_cost: nil,
      cost_status: LlmCostTracker::Charges::CostStatus::UNKNOWN
    )

    response = get("/llm-costs/calls/#{call.id}")

    expect(response.status).to eq(200)
    expect(response.body).to include("Unknown")
    expect(response.body).to include("n/a")
    expect(response.body).to include("Pricing not available for this call.")
  end

  it "renders free and partial pricing status states on call details" do
    free_call = create_call(
      model: "free-call",
      total_cost: 0,
      cost_status: LlmCostTracker::Charges::CostStatus::FREE
    )
    partial_call = create_call(
      model: "partial-call",
      total_cost: 0.25,
      cost_status: LlmCostTracker::Charges::CostStatus::PARTIAL
    )

    free_response = get("/llm-costs/calls/#{free_call.id}")
    partial_response = get("/llm-costs/calls/#{partial_call.id}")

    expect(free_response.status).to eq(200)
    expect(free_response.body).to include("Free")
    expect(partial_response.status).to eq(200)
    expect(partial_response.body).to include("Partial")
  end

  it "renders optional metadata on call details when the column exists" do
    ActiveRecord::Base.connection.add_column :llm_cost_tracker_calls, :metadata, :text
    LlmCostTracker::Call.reset_column_information
    call = create_call
    call.update!(metadata: { request_id: "req_123" }.to_json)

    response = get("/llm-costs/calls/#{call.id}")

    expect(response.status).to eq(200)
    expect(response.body).to include("Metadata")
    expect(response.body).to include("request_id")
    expect(response.body).to include("req_123")
  end

  it "includes provider capture dimensions in CSV exports" do
    create_call(
      provider_response_id: "chatcmpl_csv_123",
      provider_project_id: "proj_csv_123",
      provider_api_key_id: "key_csv_123",
      provider_workspace_id: "workspace_csv_123",
      batch: true
    )

    response = get("/llm-costs/calls.csv")

    expect(response.status).to eq(200)
    expect(response.body).to include("provider_response_id")
    expect(response.body).to include("chatcmpl_csv_123")
    expect(response.body).to include("provider_project_id")
    expect(response.body).not_to include("proj_csv_123")
    expect(response.body).to include("provider_api_key_id")
    expect(response.body).not_to include("key_csv_123")
    expect(response.body).to include("***_123")
    expect(response.body).to include("provider_workspace_id")
    expect(response.body).not_to include("workspace_csv_123")
    expect(response.body).to include("batch")
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
    drop_calls_table_with_dependents!
    LlmCostTracker::Call.reset_column_information

    response = get("/llm-costs/calls")

    expect(response.status).to eq(200)
    expect(response.body).to include("llm_cost_tracker_calls")
    expect(response.body).to include("rails generate llm_cost_tracker:install")
  end

  it "renders a database error when the database is unavailable" do
    allow(LlmCostTracker::Call).to receive(:table_exists?)
      .and_raise(ActiveRecord::ConnectionNotEstablished, "database unavailable")

    response = get("/llm-costs/calls")

    expect(response.status).to eq(500)
    expect(response.body).to include("Database unavailable")
  end

  it "renders a call details setup state when the ledger table is missing" do
    drop_calls_table_with_dependents!
    LlmCostTracker::Call.reset_column_information

    response = get("/llm-costs/calls/1")

    expect(response.status).to eq(200)
    expect(response.body).to include("llm_cost_tracker_calls")
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

  it "labels the export link with the cap when more calls match than one export holds" do
    stub_const("LlmCostTracker::CallsController::CSV_EXPORT_LIMIT", 2)
    2.times { create_call }

    expect(get("/llm-costs/calls").body).to include(">Export CSV</a>")
    create_call
    expect(get("/llm-costs/calls").body).to include("Export CSV (first 2)")
  end

  it "exports every sort in the page's order across batch boundaries, up to the export limit" do
    stub_const("LlmCostTracker::CallsController::CSV_EXPORT_BATCH_SIZE", 2)
    stub_const("LlmCostTracker::CallsController::CSV_EXPORT_LIMIT", 7)
    create_tied_export_calls
    sorts = %w[tracked_at provider model input output cost latency].product(%w[asc desc])

    csv_orders = sorts.to_h { |sort, dir| [[sort, dir], csv_labels("sort=#{sort}&dir=#{dir}")] }
    page_orders = sorts.to_h { |sort, dir| [[sort, dir], page_labels("sort=#{sort}&dir=#{dir}").first(7)] }

    expect(csv_orders).to eq(page_orders)
  end

  it "exports only filtered calls in batches without OFFSET, keeping MySQL off index skip scans" do
    stub_const("LlmCostTracker::CallsController::CSV_EXPORT_BATCH_SIZE", 2)
    create_tied_export_calls
    sql = []
    record_sql = ->(*, payload) { sql << payload[:sql] }
    mysql_hints = LlmCostTracker::Ledger::Schema::Adapter.mysql?(ActiveRecord::Base.connection) ? 1 : 0

    labels = ActiveSupport::Notifications.subscribed(record_sql, "sql.active_record") do
      csv_labels("provider=openai&tag%5Bfeature%5D=chat&sort=cost&dir=asc")
    end

    expect(labels).to eq(%w[row-3 row-0 row-5 row-1])
    expect(sql.grep(/OFFSET/i)).to be_empty
    expect(sql.grep(/llm_cost_tracker_calls\W?\.\*/).size).to eq(2)
    expect(sql.grep(/NO_SKIP_SCAN/).size).to eq(mysql_hints)
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

  it "keeps a nested tag filter in the filter pill forms" do
    create_call(total_cost: 5.0, tags: { "env" => "prod" })
    create_call(total_cost: 7.0, tags: { "env" => "dev" })

    response = Rack::MockRequest.new(Rails.application).get("/llm-costs/calls?tag%5Benv%5D=prod")

    expect(response.status).to eq(200)
    expect(response.body).to include(%(name="tag[env]" value="prod"))
    expect(response.body).not_to include(%(name="tag" value="env prod"))
  end

  it "rejects more tag filters than the limit as a bad request on the page and the CSV export" do
    create_call(tags: { feature: "chat" })
    query = (1..11).map { |i| "tag%5Bk#{i}%5D=v" }.join("&")

    [get("/llm-costs/calls?#{query}"), get("/llm-costs/calls.csv?#{query}")].each do |response|
      expect(response.status).to eq(400)
      expect(response.headers["Content-Type"]).to include("text/html")
      expect(response.body).to include("at most 10 tag filters are allowed")
    end
  end

  it "renders a missing call requested as CSV as not found" do
    response = get("/llm-costs/calls/999999.csv")

    expect(response.status).to eq(404)
    expect(response.body).to include("Call not found")
  end

  it "renders a database error during the CSV export as the HTML error page" do
    create_call
    allow(LlmCostTracker::Dashboard::Filter).to receive(:call).and_wrap_original do |original, **kwargs|
      original.call(**kwargs).where("lct_no_such_column = 1")
    end

    response = get("/llm-costs/calls.csv")

    expect(response.status).to eq(500)
    expect(response.headers["Content-Type"]).to include("text/html")
    expect(response.body).to include("Database unavailable")
  end

  it "treats a NUL byte in a tag filter value as matching nothing on PostgreSQL" do
    skip "PostgreSQL text columns cannot hold a NUL byte" unless
      LlmCostTracker::Ledger::Schema::Adapter.postgresql?(ActiveRecord::Base.connection)
    call = create_call(tags: { feature: "chat" })

    page = get("/llm-costs/calls?tag%5Bfeature%5D=a%00b")
    csv = get("/llm-costs/calls.csv?tag%5Bfeature%5D=a%00b")

    expect(page.status).to eq(200)
    expect(page.body).not_to include("/llm-costs/calls/#{call.id}")
    expect(csv.status).to eq(200)
    expect(csv.body.lines.size).to eq(1)
  end

  it "exports calls without tag rows as empty JSON" do
    create_call(tags: {})

    response = get("/llm-costs/calls.csv")

    expect(response.status).to eq(200)
    expect(response.body).to include("{}")
  end

  def create_tied_export_calls
    late = Time.utc(2026, 4, 18, 12)
    early = Time.utc(2026, 4, 18, 11)
    [
      ["openai", "gpt-4o", 10, 5, 2.0, 100, late, { feature: "chat" }],
      ["openai", "gpt-4o", 10, 5, nil, nil, late, { feature: "chat" }],
      ["anthropic", "claude-haiku-4-5", 20, 5, 2.0, 100, late, {}],
      ["openai", "gpt-4o-mini", 10, 7, 1.0, nil, early, { feature: "chat" }],
      ["anthropic", "claude-haiku-4-5", 20, 7, nil, 300, late, {}],
      ["openai", "gpt-4o", 10, 5, 2.0, 100, early, { feature: "chat" }],
      ["openai", "gpt-4o-mini", 20, 5, 1.0, 300, late, {}],
      ["anthropic", "claude-haiku-4-5", 10, 7, nil, nil, early, { feature: "chat" }],
      ["openai", "gpt-4o", 20, 7, 2.0, 100, late, {}]
    ].each_with_index do |(provider, model, input, output, cost, latency, tracked_at, tags), index|
      create_call(provider: provider, model: model, input_tokens: input, output_tokens: output, total_cost: cost,
                  latency_ms: latency, tracked_at: tracked_at, tags: tags, provider_response_id: "row-#{index}")
    end
  end

  def csv_labels(query)
    get("/llm-costs/calls.csv?#{query}").body.scan(/row-\d+/)
  end

  def page_labels(query)
    labels = LlmCostTracker::Call.pluck(:id, :provider_response_id).to_h
    get("/llm-costs/calls?#{query}&per=200").body.scan(%r{/llm-costs/calls/(\d+)"}).map { |(id)| labels.fetch(id.to_i) }
  end
end
