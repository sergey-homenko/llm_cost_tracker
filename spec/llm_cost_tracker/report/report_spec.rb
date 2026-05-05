# frozen_string_literal: true

require "active_record"
require "spec_helper"

RSpec.describe LlmCostTracker::Report do
  before do
    establish_database_connection!

    create_lct_tables!

    LlmCostTracker::Call.reset_column_information
    LlmCostTracker::ServiceCharge.reset_column_information
    LlmCostTracker::CallRollup.reset_column_information
    LlmCostTracker::Ingestion::InboxEntry.reset_column_information
    LlmCostTracker::Ingestion::Lease.reset_column_information
    allow(LlmCostTracker::Ingestion::Worker).to receive(:ensure_started)

    LlmCostTracker.configure do |config|
      config.report_tag_breakdowns = %w[feature]
    end
  end

  after do
    disconnect_database!
  end

  def create_report_call(model:, total_cost:, tags: {}, provider: "openai", tracked_at: Time.now.utc)
    LlmCostTracker::Call.create!(
      provider: provider,
      model: model,
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      total_cost: total_cost,
      cost_status: total_cost.nil? ? LlmCostTracker::Billing::CostStatus::UNKNOWN : LlmCostTracker::Billing::CostStatus::COMPLETE,
      tags: tags_for_database(tags),
      tracked_at: tracked_at
    )
  end

  def create_ranked_report_calls(now)
    6.times do |index|
      create_report_call(
        provider: "provider-#{index}",
        model: "model-#{index}",
        total_cost: index + 1,
        tags: { feature: "value-#{index}" },
        tracked_at: now - 1.hour
      )
    end
  end

  def track_and_flush(**kwargs)
    event = LlmCostTracker.track(**kwargs)
    LlmCostTracker::Ingestion::Worker.flush!
    event
  end

  it "renders a text cost report from ActiveRecord storage" do
    track_and_flush(
      provider: :openai,
      model: "gpt-4o",
      tokens: { input: 1_000, output: 0 },
      latency_ms: 100,
      tags: { feature: "chat" }
    )
    track_and_flush(
      provider: :openai,
      model: "gpt-4o-mini",
      tokens: { input: 1_000, output: 0 },
      latency_ms: 300,
      tags: { feature: "summarizer" }
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
    track_and_flush(
      provider: :openai,
      model: "gpt-4o",
      tokens: { input: 1_000, output: 0 },
      tags: { feature: "chat" }
    )

    data = LlmCostTracker::Report::Data.build(days: 30, now: Time.now.utc)

    expect(data).to be_a(LlmCostTracker::Report::Data)
    expect(data.total_cost).to eq(0.0025)
    expect(data.cost_by_tags.fetch("feature").map { |row| [row.name, row.total_cost.to_f] }).to eq([["chat", 0.0025]])
    expect(data.top_calls.first.model).to eq("gpt-4o")
  end

  it "keeps structured report data complete" do
    now = Time.utc(2026, 4, 27, 12)
    create_ranked_report_calls(now)

    data = LlmCostTracker::Report::Data.build(days: 30, now: now)

    expect(data.cost_by_provider.map(&:name)).to eq(
      %w[provider-5 provider-4 provider-3 provider-2 provider-1 provider-0]
    )
    expect(data.cost_by_model.map(&:name)).to eq(%w[model-5 model-4 model-3 model-2 model-1 model-0])
    expect(data.cost_by_tags.fetch("feature").map(&:name)).to eq(
      %w[value-5 value-4 value-3 value-2 value-1 value-0]
    )
  end

  it "limits generated report text to the rendered top values" do
    now = Time.utc(2026, 4, 27, 12)
    create_ranked_report_calls(now)

    report = described_class.generate(days: 30, now: now)

    expect(report).to include("provider-5")
    expect(report).to include("model-5")
    expect(report).to include("value-5")
    expect(report).not_to include("provider-0")
    expect(report).not_to include("model-0")
    expect(report).not_to include("value-0")
  end
end
