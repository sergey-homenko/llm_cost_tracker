# frozen_string_literal: true

require "spec_helper"
require_relative "../../dummy/config/environment"
require "llm_cost_tracker/pricing/backfill"

RSpec.describe LlmCostTracker::Pricing::Backfill do
  include_context "with mounted llm cost tracker engine"

  def add_line_items(call, rows)
    rows.each.with_index do |attrs, index|
      LlmCostTracker::CallLineItem.create!(
        llm_cost_tracker_call_id: call.id,
        position: index,
        kind: attrs[:kind] || "text_token",
        direction: attrs.fetch(:direction),
        modality: "text",
        cache_state: "none",
        unit: attrs.fetch(:unit, "token"),
        quantity: attrs.fetch(:quantity),
        rate_amount: attrs[:rate_amount],
        rate_quantity: attrs[:rate_quantity] || 1,
        cost: attrs[:cost],
        currency: "USD",
        cost_status: attrs.fetch(:cost_status, "unknown"),
        price_key: attrs[:price_key]
      )
    end
  end

  it "recomputes total_cost, snapshot, and per-component costs when pricing is now available" do
    call = create_call(
      provider: "openai", model: "gpt-4o",
      input_tokens: 1_000, output_tokens: 500,
      total_cost: nil, pricing_snapshot: nil, cost_status: "unknown"
    )
    add_line_items(call, [
                     { direction: "input", quantity: 1_000, price_key: "input" },
                     { direction: "output", quantity: 500, price_key: "output" }
                   ])

    result = described_class.call

    expect(result.examined).to eq(1)
    expect(result.recomputed).to eq(1)
    expect(result.still_unknown).to eq(0)

    call.reload
    expect(call.total_cost).to be > 0
    expect(call.cost_status).to eq(LlmCostTracker::Charges::CostStatus::COMPLETE)
    expect(call.pricing_snapshot).to be_a(Hash)
    expect(call.line_items.first.cost).to be > 0
    expect(call.line_items.first.cost_status).to eq("complete")
  end

  it "maps recomputed rates to token rows by dimension, not by stored position" do
    call = create_call(
      provider: "openai", model: "gpt-4o",
      input_tokens: 1_000, output_tokens: 500,
      total_cost: nil, pricing_snapshot: nil, cost_status: "unknown"
    )
    add_line_items(call, [
                     { direction: "output", quantity: 500 },
                     { direction: "input", quantity: 1_000 }
                   ])

    described_class.call

    by_direction = call.reload.line_items.index_by(&:direction)
    expect(by_direction.fetch("input").price_key).to eq("input")
    expect(by_direction.fetch("output").price_key).to eq("output")
  end

  it "leaves the call alone when its model is still not in the pricing registry" do
    call = create_call(
      provider: "openai", model: "gpt-future-unreleased",
      total_cost: nil, pricing_snapshot: nil, cost_status: "unknown"
    )
    add_line_items(call, [{ direction: "input", quantity: 100, price_key: "input" }])

    result = described_class.call

    expect(result.recomputed).to eq(0)
    expect(result.still_unknown).to eq(1)
    expect(call.reload.total_cost).to be_nil
    expect(call.cost_status).to eq("unknown")
  end

  it "is idempotent: a second run no longer touches already-priced rows" do
    call = create_call(
      provider: "openai", model: "gpt-4o",
      input_tokens: 1_000, output_tokens: 500,
      total_cost: nil, pricing_snapshot: nil, cost_status: "unknown"
    )
    add_line_items(call, [
                     { direction: "input", quantity: 1_000, price_key: "input" },
                     { direction: "output", quantity: 500, price_key: "output" }
                   ])

    first = described_class.call
    second = described_class.call

    expect(first.recomputed).to eq(1)
    expect(second.examined).to eq(0)
    expect(second.recomputed).to eq(0)
  end

  it "increments the call_rollups bucket for the recomputed call" do
    create_call(
      provider: "openai", model: "gpt-4o",
      input_tokens: 1_000, output_tokens: 500,
      total_cost: nil, pricing_snapshot: nil, cost_status: "unknown",
      tracked_at: Time.utc(2026, 5, 13, 12)
    )
    add_line_items(LlmCostTracker::Call.last, [
                     { direction: "input", quantity: 1_000, price_key: "input" },
                     { direction: "output", quantity: 500, price_key: "output" }
                   ])

    expect { described_class.call }.to change {
      LlmCostTracker::CallRollup.where(period: "day", period_start: Date.new(2026, 5, 13))
                                .sum(:total_cost)
    }.from(0).to(be > 0)
  end

  it "reprices a partial call and adds only the missing difference to the rollups" do
    LlmCostTracker.configuration.ingestion.mode = :inline
    LlmCostTracker.track(
      provider: "anthropic", model: "claude-opus-4-1-20250805",
      tokens: { input_tokens: 12_000, output_tokens: 800 }, tags: { feature: "research" },
      service_line_items: [{ dimension_key: "web_search_request", quantity: 2 }]
    )
    create_call(usage_source: "unknown", total_cost: 0, cost_status: "unknown")
    call = LlmCostTracker::Call.first
    expect([call.total_cost, call.cost_status]).to eq([0.02, "partial"])

    LlmCostTracker.configuration.pricing.overrides = { "anthropic/claude-opus-4-1" => { input: 15.0, output: 75.0 } }
    LlmCostTracker::Pricing::Registry.reset!

    expect(described_class.call.to_h).to eq(examined: 1, recomputed: 1, still_unknown: 0)
    # Anthropic: Opus 4.1 $15 / $75 per MTok; web search $10 per 1,000 searches.
    expect([call.reload.total_cost, call.cost_status]).to eq([0.26, "complete"])
    expect(LlmCostTracker::CallTag.where(llm_cost_tracker_call_id: call.id).pluck(:total_cost)).to eq([0.26])
    expect(LlmCostTracker::CallRollup.where(period: "month").sum(:total_cost)).to eq(0.26)
  end

  it "leaves a partial call alone when nothing new is priced or its recorded rates changed" do
    LlmCostTracker.configuration.ingestion.mode = :inline
    LlmCostTracker.configuration.pricing.overrides = { "openai/lct-probe-model" => { input: 2.0 } }
    LlmCostTracker::Pricing::Registry.reset!
    LlmCostTracker.track(provider: "openai", model: "lct-probe-model",
                         tokens: { input_tokens: 1_000_000, output_tokens: 1_000 })
    call = LlmCostTracker::Call.first

    expect(described_class.call.to_h).to eq(examined: 1, recomputed: 0, still_unknown: 1)

    LlmCostTracker.configuration.pricing.overrides = { "openai/lct-probe-model" => { input: 1.0 } }
    LlmCostTracker::Pricing::Registry.reset!

    expect(described_class.call.to_h).to eq(examined: 1, recomputed: 0, still_unknown: 1)
    expect([call.reload.total_cost, call.cost_status]).to eq([2.0, "partial"])
    expect(call.line_items.find_by(direction: "input").rate_amount).to eq(2.0)
  end

  it "does not touch rollups when cache_rollups is disabled and the rollups table is absent" do
    LlmCostTracker.configuration.budgets.totals_source = :ledger
    ActiveRecord::Base.connection.drop_table(:llm_cost_tracker_call_rollups, if_exists: true)

    call = create_call(
      provider: "openai",
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 500,
      total_cost: nil,
      pricing_snapshot: nil,
      cost_status: "unknown"
    )
    add_line_items(
      call,
      [
        { direction: "input", quantity: 1_000, price_key: "input" },
        { direction: "output", quantity: 500, price_key: "output" }
      ]
    )

    expect(described_class.call.recomputed).to eq(1)
  end
end
