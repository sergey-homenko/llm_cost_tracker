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

  it "renders a daily spend timeseries when a value is selected" do
    create_call(total_cost: 2.0, tracked_at: Date.current.to_time, tags: { feature: "chat" })
    create_call(total_cost: 3.0, tracked_at: (Date.current - 1).to_time, tags: { feature: "chat" })
    create_call(total_cost: 1.0, tracked_at: Date.current.to_time, tags: { feature: "summarizer" })

    response = get("/llm-costs/tags/feature", params: { tag_value: "chat" })

    expect(response.status).to eq(200)
    expect(response.body).to include("feature")
    expect(response.body).to include("chat")
    expect(response.body).to include("Spend over time")
    expect(response.body).to include("$5.00")
    expect(response.body).to include("$2.50")
    expect(response.body).not_to include("summarizer")
    expect(response.body).to include("← All values for feature")
  end

  it "preserves the drill-down value through the filter form via a hidden field" do
    create_call(total_cost: 2.0, tags: { feature: "chat" })

    response = get("/llm-costs/tags/feature", params: { tag_value: "chat" })

    expect(response.body).to match(%r{<input[^>]+type="hidden"[^>]+name="tag_value"[^>]+value="chat"})
  end

  it "renders an empty timeseries state when no calls carry the chosen tag value" do
    create_call(total_cost: 2.0, tags: { feature: "chat" })

    response = get("/llm-costs/tags/feature", params: { tag_value: "missing" })

    expect(response.status).to eq(200)
    expect(response.body).to include("No calls tagged with feature=missing")
    expect(response.body).not_to include("Spend over time")
  end

  it "exposes a Trend link from the breakdown row to the value timeseries" do
    create_call(total_cost: 2.0, tags: { feature: "chat" })

    response = get("/llm-costs/tags/feature")

    expect(response.body).to match(%r{href="[^"]*/llm-costs/tags/feature\?[^"]*tag_value=chat[^"]*"[^>]*>\s*Trend\s*</a>})
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

  it "routes tag keys that contain a dot, including ones ending in a file extension" do
    create_call(total_cost: 2.0, tags: { "team.name" => "core", "request.json" => "core" })

    %w[team.name request.json].each do |key|
      breakdown = get("/llm-costs/tags/#{key}")
      value = get("/llm-costs/tags/#{key}", params: { tag_value: "core" })

      expect(breakdown.status).to eq(200)
      expect(breakdown.headers["Content-Type"]).to include("text/html")
      expect(breakdown.body).to match(%r{href="[^"]*/llm-costs/tags/#{Regexp.escape(key)}\?[^"]*tag_value=core[^"]*"})
      expect(value.status).to eq(200)
      expect(value.body).to include("$2.00")
    end
  end

  it "offers drill-down links only while they stay within the tag filter limit" do
    others = (1..10).to_h { |i| ["k#{i}", "v"] }
    create_call(total_cost: 2.0, tags: others.merge("feature" => "chat"))

    at_limit = get("/llm-costs/tags/feature?#{{ tag: others }.to_query}")
    below_limit = get("/llm-costs/tags/feature?#{{ tag: others.except('k10') }.to_query}")
    own_key = get("/llm-costs/tags/feature?#{{ tag: others.except('k10').merge('feature' => 'chat') }.to_query}")

    expect(at_limit.status).to eq(200)
    expect(at_limit.body).to include("tag filter limit")
    expect(at_limit.body).not_to include(">Trend</a>")
    expect(below_limit.body).to include(">Trend</a>")
    expect(own_key.body).to include(">Trend</a>")
  end

  it "shows the chosen value even when a filter on the same key disagrees" do
    create_call(total_cost: 2.0, tags: { feature: "chat" })
    create_call(total_cost: 3.0, tags: { feature: "search" })

    response = get("/llm-costs/tags/feature?#{{ tag: { feature: 'chat' }, tag_value: 'search' }.to_query}")

    expect(response.status).to eq(200)
    expect(response.body).to include("$3.00")
    expect(response.body).not_to include("No calls tagged with feature=search")
  end

  it "counts the tag value toward the tag filter limit" do
    tags = (1..10).to_h { |i| ["k#{i}", "v"] }

    response = get("/llm-costs/tags/feature?#{{ tag: tags, tag_value: 'chat' }.to_query}")

    expect(response.status).to eq(400)
    expect(response.body).to include("at most 10 tag filters are allowed, got 11")
  end

  it "rejects a list or a hash in the tag value as a bad request" do
    list = get("/llm-costs/tags/feature?tag_value%5B%5D=a&tag_value%5B%5D=b")
    hash = get("/llm-costs/tags/feature?tag_value%5Bx%5D=y")

    [list, hash].each do |response|
      expect(response.status).to eq(400)
      expect(response.body).to include("tag_value must be a single value")
    end
  end

  it "treats a NUL byte in the tag value as matching nothing on PostgreSQL" do
    skip "PostgreSQL text columns cannot hold a NUL byte" unless
      LlmCostTracker::Ledger::Schema::Adapter.postgresql?(ActiveRecord::Base.connection)
    create_call(tags: { feature: "chat" })

    response = get("/llm-costs/tags/feature?tag_value=a%00b")

    expect(response.status).to eq(200)
    expect(response.body).to include("No calls tagged with feature=")
  end

  it "renders a setup state when the ledger table is missing" do
    drop_calls_table_with_dependents!
    LlmCostTracker::Call.reset_column_information

    response = get("/llm-costs/tags/feature")

    expect(response.status).to eq(200)
    expect(response.body).to include("llm_cost_tracker_calls")
    expect(response.body).to include("rails generate llm_cost_tracker:install")
  end
end
