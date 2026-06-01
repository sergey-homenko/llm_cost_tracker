# frozen_string_literal: true

require "spec_helper"

require_relative "../../dummy/config/environment"

RSpec.describe LlmCostTracker::Ledger::Rollups do
  include_context "with mounted llm cost tracker engine"

  def build_event(total_cost:, currency: "USD", tracked_at: Time.now.utc)
    LlmCostTracker::Event.new(
      event_id: SecureRandom.uuid,
      provider: "openai",
      model: "gpt-4o",
      token_usage: LlmCostTracker::Usage::TokenUsage.build(input_tokens: 1, output_tokens: 1),
      pricing_mode: nil,
      cost: LlmCostTracker::Charges::Cost.new(components: {}, total: total_cost, currency: currency),
      tags: {},
      latency_ms: nil,
      stream: false,
      usage_source: "response",
      provider_response_id: nil,
      provider_project_id: nil,
      provider_api_key_id: nil,
      provider_workspace_id: nil,
      tracked_at: tracked_at,
      cost_status: LlmCostTracker::Charges::CostStatus::COMPLETE,
      pricing_snapshot: { "currency" => currency },
      line_items: []
    )
  end

  describe ".increment!" do
    it "writes a separate rollup row per currency" do
      time = Time.utc(2026, 5, 7, 12)
      described_class.increment!([build_event(total_cost: 1.5, currency: "USD", tracked_at: time)])
      described_class.increment!([build_event(total_cost: 2.0, currency: "EUR", tracked_at: time)])

      rollups = LlmCostTracker::CallRollup.where(period: "month").order(:currency).pluck(:currency, :total_cost)

      expect(rollups).to eq([["EUR", 2.0], ["USD", 1.5]])
    end

    it "falls back to USD when the pricing snapshot has no currency" do
      time = Time.utc(2026, 5, 7, 12)
      event = build_event(total_cost: 1.0, tracked_at: time)
      event = event.with(pricing_snapshot: nil)

      described_class.increment!([event])

      rollup = LlmCostTracker::CallRollup.find_by(period: "month")
      expect(rollup.currency).to eq("USD")
    end
  end

  describe ".decrement!" do
    it "scopes the deduction to the snapshot currency, leaving other currency rows untouched" do
      time = Time.utc(2026, 5, 7, 12)
      described_class.increment!([build_event(total_cost: 5.0, currency: "USD", tracked_at: time)])
      described_class.increment!([build_event(total_cost: 3.0, currency: "EUR", tracked_at: time)])

      described_class.decrement!([[1, time, BigDecimal("3.0"), { "currency" => "EUR" }, "openai"]])

      remaining = LlmCostTracker::CallRollup.where(period: "month").order(:currency).pluck(:currency, :total_cost)
      expect(remaining).to eq([["EUR", 0.0], ["USD", 5.0]])
    end
  end

  describe "Period::Totals integration" do
    it "sums rollups across all currencies when cache_rollups is enabled" do
      LlmCostTracker.configure { |config| config.cache_rollups = true }
      time = Time.utc(2026, 5, 7, 12)
      described_class.increment!([build_event(total_cost: 4.5, currency: "USD", tracked_at: time)])
      described_class.increment!([build_event(total_cost: 99.0, currency: "EUR", tracked_at: time)])

      totals = LlmCostTracker::Ledger::Period::Totals.call(%i[day month], time: time)

      expect(totals[:day]).to be_within(0.0001).of(103.5)
      expect(totals[:month]).to be_within(0.0001).of(103.5)
    end

    it "falls back to live aggregation from calls when the rollups table has been truncated" do
      LlmCostTracker.configure { |config| config.cache_rollups = true }
      time = Time.utc(2026, 5, 7, 12)
      LlmCostTracker::Ledger::Store.insert([
                                                  build_event(total_cost: 4.5, currency: "USD", tracked_at: time),
                                                  build_event(total_cost: 99.0, currency: "EUR", tracked_at: time)
                                                ])
      LlmCostTracker::CallRollup.delete_all

      totals = LlmCostTracker::Ledger::Period::Totals.call(%i[day month], time: time)

      expect(totals[:day]).to be_within(0.0001).of(103.5)
      expect(totals[:month]).to be_within(0.0001).of(103.5)
    end

    it "prefers calls aggregation over a stale partial rollup row so a post-v0.9-migration period with historical pre-migration calls is not under-counted while the new rollup bucket only contains the post-migration tail" do
      LlmCostTracker.configure { |config| config.cache_rollups = true }
      time = Time.utc(2026, 5, 15, 12)
      LlmCostTracker::Ledger::Store.insert([
                                                  build_event(total_cost: 50.0, currency: "USD", tracked_at: time),
                                                  build_event(total_cost: 50.0, currency: "USD", tracked_at: time)
                                                ])
      LlmCostTracker::CallRollup.where(period: "month").update_all(total_cost: 5.0)

      totals = LlmCostTracker::Ledger::Period::Totals.call(%i[month], time: time)

      expect(totals[:month]).to be_within(0.0001).of(100.0)
    end
  end
end
