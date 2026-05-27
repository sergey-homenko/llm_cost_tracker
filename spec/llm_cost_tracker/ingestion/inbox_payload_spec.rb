# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe LlmCostTracker::Ingestion::Inbox do
  let(:row_class) { Struct.new(:payload) }
  let(:event) do
    LlmCostTracker::Event.new(
      event_id: "evt_payload_1",
      provider: "openai",
      model: "gpt-4o",
      token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 100, output_tokens: 50),
      pricing_mode: :batch,
      cost: {
        input_cost: 0.10,
        output_cost: 0.20,
        total_cost: 0.30
      },
      tags: { feature: "chat" },
      latency_ms: 25,
      stream: false,
      usage_source: "manual",
      provider_response_id: "resp_payload_1",
      provider_project_id: "proj_payload_1",
      provider_api_key_id: "key_payload_1",
      provider_workspace_id: "workspace_payload_1",
      tracked_at: Time.utc(2026, 4, 18, 12, 0, 0),
      cost_status: LlmCostTracker::Billing::CostStatus::COMPLETE,
      pricing_snapshot: {
        schema_version: 1,
        source: "bundled",
        currency: "USD",
        rates: {
          input: { amount: 2.5, quantity: 1_000_000 }
        }
      },
      line_items: [
        LlmCostTracker::Billing::LineItem.build(
          component_key: "web_search_request",
          quantity: 1,
          cost_status: LlmCostTracker::Billing::CostStatus::UNKNOWN
        )
      ]
    )
  end

  it "writes a schema version into inbox payload rows" do
    row = described_class.send(:row_for, event)
    payload = JSON.parse(row.fetch(:payload))

    expect(payload.fetch("schema_version")).to eq(described_class::PAYLOAD_SCHEMA_VERSION)
  end

  it "reads current versioned payload rows" do
    row = described_class.send(:row_for, event)
    restored = described_class.event_from_row(row_class.new(row.fetch(:payload)))

    expect(restored.event_id).to eq("evt_payload_1")
    expect(restored.token_usage.input_tokens).to eq(100)
    expect(restored.total_cost.to_f).to eq(0.3)
    expect(restored.tags).to eq(feature: "chat")
    expect(restored.cost_status).to eq(LlmCostTracker::Billing::CostStatus::COMPLETE)
    expect(restored.pricing_snapshot.fetch(:schema_version)).to eq(1)
    expect(restored.usage_source).to eq("manual")
    expect(restored.provider_project_id).to eq("proj_payload_1")
    expect(restored.provider_api_key_id).to eq("key_payload_1")
    expect(restored.provider_workspace_id).to eq("workspace_payload_1")
    expect(restored.batch?).to be true
    expect(restored.line_items.first.kind).to eq("web_search_request")
  end

  it "preserves BigDecimal cost precision through the JSON payload round-trip" do
    high_precision_event = event.with(cost: { total_cost: BigDecimal("0.0001234567890123456789") })

    row = described_class.send(:row_for, high_precision_event)
    restored = described_class.event_from_row(row_class.new(row.fetch(:payload)))

    expect(restored.total_cost).to eq(BigDecimal("0.0001234567890123456789"))
    expect(restored.total_cost).to be_a(BigDecimal)
  end

  it "rejects payloads from older schema versions" do
    row = described_class.send(:row_for, event)
    payload = JSON.parse(row.fetch(:payload)).merge("schema_version" => 1)

    expect do
      described_class.event_from_row(row_class.new(JSON.generate(payload)))
    end.to raise_error(LlmCostTracker::Error, /unsupported ledger inbox payload schema version/)
  end

  it "rejects unsupported future payload versions" do
    row = described_class.send(:row_for, event)
    payload = JSON.parse(row.fetch(:payload)).merge("schema_version" => 999)

    expect do
      described_class.event_from_row(row_class.new(JSON.generate(payload)))
    end.to raise_error(LlmCostTracker::Error, /unsupported ledger inbox payload schema version/)
  end
end
