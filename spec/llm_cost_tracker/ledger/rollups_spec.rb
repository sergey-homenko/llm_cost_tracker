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

      record = Struct.new(:tracked_at, :total_cost, :pricing_snapshot, :provider)
                     .new(time, BigDecimal("3.0"), { "currency" => "EUR" }, "openai")
      described_class.decrement!([record])

      remaining = LlmCostTracker::CallRollup.where(period: "month").order(:currency).pluck(:currency, :total_cost)
      expect(remaining).to eq([["EUR", 0.0], ["USD", 5.0]])
    end
  end

  describe "with cache_rollups enabled but the rollups table missing" do
    before do
      LlmCostTracker.configure { |config| config.cache_period_totals = true }
      LlmCostTracker::Ledger::Store.insert([build_event(total_cost: 4.5, tracked_at: Time.utc(2026, 5, 7, 12))])
      ActiveRecord::Base.connection.drop_table(:llm_cost_tracker_call_rollups, if_exists: true)
      LlmCostTracker::CallRollup.reset_column_information
    end

    it "aggregates budget totals from calls instead of raising" do
      time = Time.utc(2026, 5, 7, 12)

      totals = LlmCostTracker::Ledger::Period::Totals.call(%i[day month], time: time)

      expect(totals[:day]).to be_within(0.0001).of(4.5)
      expect(totals[:month]).to be_within(0.0001).of(4.5)
    end

    it "warns once that the fast path is unavailable" do
      logged = []
      allow(LlmCostTracker::Logging).to receive(:warn) { |message| logged << message }

      2.times { LlmCostTracker::Ledger::Period::Totals.call(%i[day], time: Time.utc(2026, 5, 7, 12)) }

      expect(logged.size).to eq(1)
      expect(logged.first).to include("llm_cost_tracker_call_rollups is missing")
    end
  end

  describe "with cache_rollups disabled" do
    it "writes no rollup rows on increment!" do
      LlmCostTracker.configuration.cache_period_totals = false

      described_class.increment!([build_event(total_cost: 1.5)])

      expect(LlmCostTracker::CallRollup.count).to eq(0)
    end

    it "leaves rollup rows untouched on decrement!" do
      time = Time.utc(2026, 5, 7, 12)
      described_class.increment!([build_event(total_cost: 5.0, tracked_at: time)])
      LlmCostTracker.configuration.cache_period_totals = false

      record = Struct.new(:tracked_at, :total_cost, :pricing_snapshot, :provider)
                     .new(time, BigDecimal("5.0"), { "currency" => "USD" }, "openai")
      described_class.decrement!([record])

      expect(LlmCostTracker::CallRollup.where(period: "month").pluck(:total_cost)).to eq([5.0])
    end
  end

  describe "Period::Totals integration" do
    it "sums rollups across all currencies when cache_rollups is enabled" do
      LlmCostTracker.configure { |config| config.cache_period_totals = true }
      time = Time.utc(2026, 5, 7, 12)
      described_class.increment!([build_event(total_cost: 4.5, currency: "USD", tracked_at: time)])
      described_class.increment!([build_event(total_cost: 99.0, currency: "EUR", tracked_at: time)])

      totals = LlmCostTracker::Ledger::Period::Totals.call(%i[day month], time: time)

      expect(totals[:day]).to be_within(0.0001).of(103.5)
      expect(totals[:month]).to be_within(0.0001).of(103.5)
    end

    it "falls back to live aggregation from calls when the rollups table has been truncated" do
      LlmCostTracker.configure { |config| config.cache_period_totals = true }
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
      LlmCostTracker.configure { |config| config.cache_period_totals = true }
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

  describe ".rebuild!" do
    def seed_call(total_cost:, provider: "openai", currency: "USD", tracked_at: Time.utc(2026, 5, 7, 12))
      LlmCostTracker::Call.create!(
        event_id: SecureRandom.uuid, provider: provider, model: "gpt-4o",
        input_tokens: 0, output_tokens: 0, total_tokens: 0,
        total_cost: total_cost,
        cost_status: LlmCostTracker::Charges::CostStatus::COMPLETE,
        pricing_snapshot: { "currency" => currency },
        tracked_at: tracked_at
      )
    end

    it "reprojects rollup totals from the calls ledger per period, currency, and provider" do
      seed_call(total_cost: 1.5, currency: "USD")
      seed_call(total_cost: 2.0, currency: "USD")
      seed_call(total_cost: 3.0, currency: "EUR")
      seed_call(total_cost: 0.5, provider: "anthropic", currency: "USD")

      rows_written = described_class.rebuild!

      expect(LlmCostTracker::CallRollup.find_by(period: "month", provider: "openai", currency: "USD").total_cost).to eq(3.5)
      expect(LlmCostTracker::CallRollup.find_by(period: "month", provider: "openai", currency: "EUR").total_cost).to eq(3.0)
      expect(LlmCostTracker::CallRollup.find_by(period: "month", provider: "anthropic", currency: "USD").total_cost).to eq(0.5)
      expect(rows_written).to eq(LlmCostTracker::CallRollup.count)
    end

    it "produces the same rows incremental increment! would have written" do
      time = Time.utc(2026, 5, 7, 12)
      described_class.increment!([
                                   build_event(total_cost: 1.5, currency: "USD", tracked_at: time),
                                   build_event(total_cost: 2.0, currency: "EUR", tracked_at: time)
                                 ])
      incremental = LlmCostTracker::CallRollup.order(:period, :currency).pluck(:period, :period_start, :currency, :provider, :total_cost)

      LlmCostTracker::CallRollup.delete_all
      seed_call(total_cost: 1.5, currency: "USD", tracked_at: time)
      seed_call(total_cost: 2.0, currency: "EUR", tracked_at: time)
      described_class.rebuild!

      rebuilt = LlmCostTracker::CallRollup.order(:period, :currency).pluck(:period, :period_start, :currency, :provider, :total_cost)
      expect(rebuilt).to eq(incremental)
    end

    it "resyncs drifted rollup totals back to the ledger truth" do
      seed_call(total_cost: 4.0, currency: "USD")
      described_class.rebuild!
      LlmCostTracker::CallRollup.update_all(total_cost: 999.0)

      described_class.rebuild!

      expect(LlmCostTracker::CallRollup.where(total_cost: 999.0)).to be_empty
      expect(LlmCostTracker::CallRollup.find_by(period: "month").total_cost).to eq(4.0)
    end

    it "writes no rollup rows when no call has a cost" do
      seed_call(total_cost: nil)
      expect(described_class.rebuild!).to eq(0)
      expect(LlmCostTracker::CallRollup.count).to eq(0)
    end

    it "still rebuilds while cache_rollups is disabled, so the table can be primed before opting in" do
      seed_call(total_cost: 4.5, currency: "USD")
      LlmCostTracker.configuration.cache_period_totals = false

      expect(described_class.rebuild!).to eq(LlmCostTracker::CallRollup.count)
      expect(LlmCostTracker::CallRollup.find_by(period: "month").total_cost).to eq(4.5)
    end
  end
end
