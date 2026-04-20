# frozen_string_literal: true

require "active_record"
require "spec_helper"

RSpec.describe LlmCostTracker::Report do
  before do
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")

    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table :llm_api_calls do |t|
        t.string :provider, null: false
        t.string :model, null: false
        t.integer :input_tokens, null: false, default: 0
        t.integer :output_tokens, null: false, default: 0
        t.integer :total_tokens, null: false, default: 0
        t.decimal :input_cost, precision: 20, scale: 8
        t.decimal :output_cost, precision: 20, scale: 8
        t.decimal :total_cost, precision: 20, scale: 8
        t.integer :latency_ms
        t.text :tags
        t.datetime :tracked_at, null: false

        t.timestamps
      end
    end

    LlmCostTracker::LlmApiCall.reset_column_information if defined?(LlmCostTracker::LlmApiCall)

    LlmCostTracker.configure do |config|
      config.storage_backend = :active_record
      config.report_tag_breakdowns = %w[feature]
    end
  end

  after do
    ActiveRecord::Base.connection.disconnect!
  end

  it "renders a text cost report from ActiveRecord storage" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0,
      latency_ms: 100,
      feature: "chat"
    )
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o-mini",
      input_tokens: 1_000,
      output_tokens: 0,
      latency_ms: 300,
      feature: "summarizer"
    )

    report = described_class.generate(days: 30, now: Time.now.utc)

    expect(report).to include("LLM Cost Report")
    expect(report).to include("Total cost: $0.002650")
    expect(report).to include("Requests: 2")
    expect(report).to include("Avg latency: 200ms")
    expect(report).to include("gpt-4o")
    expect(report).to include("By tag (feature):")
    expect(report).to include("chat")
  end

  it "exposes report data separately from text formatting" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0,
      feature: "chat"
    )

    data = described_class.data(days: 30, now: Time.now.utc)

    expect(data).to be_a(LlmCostTracker::ReportData)
    expect(data.total_cost).to eq(0.0025)
    expect(data.cost_by_tags.fetch("feature")).to eq([["chat", 0.0025]])
    expect(data.top_calls.first.model).to eq("gpt-4o")
  end
end
