# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe LlmCostTracker::Ledger::Ingestion::Inbox do
  let(:row_class) { Struct.new(:payload) }

  def event
    LlmCostTracker::Event.new(
      event_id: "evt_payload_1",
      provider: "openai",
      model: "gpt-4o",
      token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 100, output_tokens: 50),
      pricing_mode: nil,
      cost: LlmCostTracker::Pricing::Cost.from_hash(
        input_cost: 0.10,
        output_cost: 0.20,
        total_cost: 0.30,
        currency: "USD"
      ),
      tags: { feature: "chat" },
      latency_ms: 25,
      stream: false,
      usage_source: "manual",
      provider_response_id: "resp_payload_1",
      tracked_at: Time.utc(2026, 4, 18, 12, 0, 0)
    )
  end

  it "writes a schema version into durable payload rows" do
    row = described_class.send(:row_for, event)
    payload = JSON.parse(row.fetch(:payload))

    expect(payload.fetch("schema_version")).to eq(described_class::PAYLOAD_SCHEMA_VERSION)
  end

  it "reads current versioned payload rows" do
    row = described_class.send(:row_for, event)
    restored = described_class.event_from_row(row_class.new(row.fetch(:payload)))

    expect(restored.event_id).to eq("evt_payload_1")
    expect(restored.token_usage.input_tokens).to eq(100)
    expect(restored.cost.total_cost.to_f).to eq(0.3)
    expect(restored.tags).to eq("feature" => "chat")
  end

  it "reads legacy flat payload rows without a schema version" do
    payload = {
      event_id: "evt_legacy_1",
      provider: "anthropic",
      model: "claude-haiku-4-5",
      input_tokens: 20,
      output_tokens: 5,
      total_tokens: 25,
      cost: { input_cost: 0.01, output_cost: 0.02, total_cost: 0.03, currency: "USD" },
      tags: { feature: "legacy" },
      latency_ms: 15,
      stream: true,
      usage_source: "stream_final",
      provider_response_id: "msg_legacy_1",
      tracked_at: "2026-04-18T12:00:00Z"
    }

    restored = described_class.event_from_row(row_class.new(JSON.generate(payload)))

    expect(restored.event_id).to eq("evt_legacy_1")
    expect(restored.token_usage.output_tokens).to eq(5)
    expect(restored.cost.total_cost.to_f).to eq(0.03)
    expect(restored.tags).to eq("feature" => "legacy")
  end

  it "rejects unsupported future payload versions" do
    row = described_class.send(:row_for, event)
    payload = JSON.parse(row.fetch(:payload)).merge("schema_version" => 999)

    expect do
      described_class.event_from_row(row_class.new(JSON.generate(payload)))
    end.to raise_error(LlmCostTracker::Error, /unsupported ledger inbox payload schema version/)
  end
end
