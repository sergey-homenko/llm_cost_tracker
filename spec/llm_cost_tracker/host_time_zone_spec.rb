# frozen_string_literal: true

require "spec_helper"
require "llm_cost_tracker/pricing/backfill"

RSpec.describe "A host app with time-zone-aware attributes and a non-UTC Time.zone" do
  include_context "with mounted llm cost tracker engine"

  let(:models) { [LlmCostTracker::Call, LlmCostTracker::CallLineItem, LlmCostTracker::CallTag, LlmCostTracker::CallRollup] }

  around do |example|
    previous = ActiveRecord::Base.time_zone_aware_attributes
    ActiveRecord::Base.time_zone_aware_attributes = true
    example.run
  ensure
    ActiveRecord::Base.time_zone_aware_attributes = previous
    models.each(&:reset_column_information)
  end

  before do
    models.each(&:reset_column_information)
    LlmCostTracker.configuration.ingestion.mode = :inline
    LlmCostTracker.configuration.pricing.unknown_model_behavior = :ignore
  end

  def track_at(time, model: "gpt-4o")
    travel_to(time) { LlmCostTracker.track(provider: "openai", model: model, tokens: { input_tokens: 1_000_000 }) }
  end

  it "rebuilds the rollups by UTC day and month" do
    track_at(Time.utc(2026, 7, 1, 3))

    Time.use_zone("America/Los_Angeles") do
      expect(LlmCostTracker::Call.sole.tracked_at).to be_a(ActiveSupport::TimeWithZone)
      LlmCostTracker::Ledger::Rollups.rebuild!
    end

    expect(LlmCostTracker::CallRollup.order(:period, :period_start).pluck(:period, :period_start))
      .to eq([["day", Date.new(2026, 7, 1)], ["month", Date.new(2026, 7, 1)]])
  end

  it "backfills a scheduled price from the call's UTC day" do
    track_at(Time.utc(2026, 7, 1, 3), model: "sched-model")
    LlmCostTracker.configuration.pricing.overrides = { "sched-model" => { "input" => 1.0, "input_from_2026-07-01" => 2.0 } }
    LlmCostTracker::Pricing::Registry.reset!

    Time.use_zone("America/Los_Angeles") { LlmCostTracker::Pricing::Backfill.call }

    expect(LlmCostTracker::Call.sole.total_cost).to eq(BigDecimal("2.0"))
  end
end
