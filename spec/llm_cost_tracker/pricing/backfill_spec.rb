# frozen_string_literal: true

require "spec_helper"
require "faraday"
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
        price_key: attrs[:price_key],
        details: {}
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

  it "reprices cached audio line items at the cached audio rate" do
    LlmCostTracker.configure do |c|
      c.pricing.overrides = {
        "openai/gpt-realtime-mini" => { input: 0.6, output: 2.4, cache_read_input: 0.06, audio_cache_read_input: 0.3 }
      }
    end
    call = create_call(
      provider: "openai", model: "gpt-realtime-mini", input_tokens: 0, output_tokens: 0,
      cache_read_input_tokens: 27_000, total_cost: nil, pricing_snapshot: nil, cost_status: "unknown"
    )
    [%w[text_token text 1800], %w[audio_token audio 25200]].each_with_index do |(kind, modality, quantity), position|
      LlmCostTracker::CallLineItem.create!(
        llm_cost_tracker_call_id: call.id, position: position, kind: kind, direction: "input", modality: modality,
        cache_state: "read", unit: "token", quantity: quantity, currency: "USD", cost_status: "unknown", details: {}
      )
    end

    described_class.call

    expect(call.reload.total_cost).to eq(BigDecimal("0.007668"))
    expect(call.line_items.find_by(kind: "audio_token")).to have_attributes(
      rate_amount: BigDecimal("0.3"), cost: BigDecimal("0.00756"), price_key: "audio_cache_read_input"
    )
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

  it "prices a call at the rate in effect on its own date" do
    LlmCostTracker.configuration.pricing.overrides = {
      "gemini/gemini-3.8-flash" => { input: 0.75, "input_from_2027-01-01": 1.50 }
    }
    LlmCostTracker::Pricing::Registry.reset!
    call = create_call(provider: "gemini", model: "gemini-3.8-flash", input_tokens: 1_000, output_tokens: 0,
                       total_cost: nil, pricing_snapshot: nil, cost_status: "unknown",
                       tracked_at: Time.utc(2026, 12, 31, 12))
    add_line_items(call, [{ direction: "input", quantity: 1_000, price_key: "input" }])

    travel_to(Time.utc(2027, 2, 1)) { described_class.call }

    # Google: Gemini 3.8 Flash input $0.75 / 1M through December 31, 2026, $1.50 from January 1, 2027.
    expect(call.reload.total_cost).to eq(0.00075)
  end

  it "reprices calls already priced at a wrong rate only in the requested range, moving rollups and tags by the delta" do
    LlmCostTracker.configuration.ingestion.mode = :inline
    LlmCostTracker.configuration.pricing.overrides = { "openai/gpt-4o-mini" => { input: 0.165, output: 0.66 } }
    LlmCostTracker::Pricing::Registry.reset!
    [Time.utc(2026, 9, 20, 12), Time.utc(2026, 9, 26, 12)].each do |time|
      travel_to(time) do
        LlmCostTracker.track(provider: "openai", model: "gpt-4o-mini",
                             tokens: { input_tokens: 1000, output_tokens: 500 }, tags: { tenant: "acme" })
      end
    end
    LlmCostTracker.configuration.pricing.overrides = {}
    LlmCostTracker::Pricing::Registry.reset!

    expect(described_class.call.recomputed).to eq(0)
    result = described_class.call(scope: described_class.reprice_scope(Time.utc(2026, 9, 21)..), reprice: true)

    # OpenAI: gpt-4o-mini $0.15 input / $0.60 output per 1M tokens.
    repriced = LlmCostTracker::Call.order(:tracked_at).last
    expect(result.to_h).to eq(examined: 1, recomputed: 1, still_unknown: 0)
    expect(LlmCostTracker::Call.order(:tracked_at).pluck(:total_cost)).to eq([0.000495, 0.00045])
    expect(LlmCostTracker::CallTag.order(:tracked_at).pluck(:total_cost)).to eq([0.000495, 0.00045])
    expect(LlmCostTracker::CallRollup.where(period: "month").sum(:total_cost)).to eq(0.000945)
    expect(repriced.line_items.order(:position).pluck(:rate_amount)).to eq([0.15, 0.6])
  end

  it "reprices tool charges priced from the registry and keeps the ones the caller priced" do
    LlmCostTracker.configuration.ingestion.mode = :inline
    LlmCostTracker.configuration.pricing.overrides = {
      "gemini/gemini-2.5-flash" => { input: 0.30, output: 2.50, maps_grounding_request: 50.0 }
    }
    LlmCostTracker::Pricing::Registry.reset!
    LlmCostTracker.track(provider: "gemini", model: "gemini-2.5-flash",
                         tokens: { input_tokens: 100, output_tokens: 300 }, tags: { tenant: "acme" },
                         service_line_items: [{ dimension_key: "maps_grounding_request", quantity: 10 },
                                              { dimension_key: "grounding_request", quantity: 1, cost: 0.123 }])
    call = LlmCostTracker::Call.first
    expect(call.total_cost).to eq(0.62378)
    LlmCostTracker.configuration.pricing.overrides = {}
    LlmCostTracker::Pricing::Registry.reset!

    result = described_class.call(scope: described_class.reprice_scope(1.hour.ago..), reprice: true)

    # Google: Gemini 2.5 Flash $0.30 input / $2.50 output per 1M tokens, Maps grounding $25 / 1,000 grounded prompts.
    expect(result.recomputed).to eq(1)
    expect([call.reload.total_cost, call.cost_status]).to eq([0.37378, "complete"])
    expect(call.line_items.where.not(unit: "token").order(:position).pluck(:kind, :cost))
      .to eq([["maps_grounding_request", 0.25], ["grounding_request", 0.123]])
    expect(LlmCostTracker::CallTag.pluck(:total_cost)).to eq([0.37378])
    expect(LlmCostTracker::CallRollup.where(period: "day").sum(:total_cost)).to eq(0.37378)
  end

  it "reprices an Anthropic advisor iteration at the advisor model's current rates" do
    LlmCostTracker.configuration.ingestion.mode = :inline
    LlmCostTracker.configuration.pricing.overrides = { "anthropic/claude-opus-5" => { input: 50.0, output: 250.0 } }
    LlmCostTracker::Pricing::Registry.reset!
    body = sdk_fixture(:anthropic, "messages_with_advisor.json")
    Faraday.new(url: "https://api.anthropic.com") do |f|
      f.use :llm_cost_tracker
      f.adapter(:test) { |stub| stub.post("/v1/messages") { [200, { "Content-Type" => "application/json" }, body] } }
    end.post("/v1/messages", { model: "claude-sonnet-5", max_tokens: 1024, messages: [] }.to_json)
    call = LlmCostTracker::Call.first
    LlmCostTracker.configuration.pricing.overrides = {}
    LlmCostTracker::Pricing::Registry.reset!

    described_class.call(scope: described_class.reprice_scope(1.hour.ago..), reprice: true)

    # Anthropic advisor tool example: Sonnet 5 executor $0.0089124 ($2 / $0.20 cache read / $10 per MTok)
    # plus Opus 5 advisor 823 x $5 + 1,612 x $25 per MTok = $0.044415.
    expect(call.line_items.find_by(kind: "model_iteration").cost).to eq(0.044415)
    expect([call.reload.total_cost, call.cost_status]).to eq([0.0533274, "complete"])
  end

  it "prices Bedrock regional-profile calls recorded before 0.14.2 with the regional premium" do
    regional, global = %w[us global].map do |geo|
      create_call(provider: "bedrock", model: "#{geo}.anthropic.claude-sonnet-4-5-20250929-v1:0",
                  input_tokens: 1_000_000, output_tokens: 100_000,
                  total_cost: nil, pricing_snapshot: nil, cost_status: "unknown")
    end

    described_class.call

    # Anthropic: Sonnet 4.5 $3 / $15 per MTok; Bedrock regional endpoints add 10% over global ones.
    expect([regional.reload.total_cost, global.reload.total_cost]).to eq([4.95, 4.5])
  end

  def record_anthropic(model:, usage:, **response)
    LlmCostTracker.configuration.ingestion.mode = :inline
    LlmCostTracker::Tracker.record(
      event: LlmCostTracker::Providers::Anthropic::ResponseParser.event_from_usage(
        usage: usage, model: model, provider_response_id: nil, usage_source: "response", **response
      )
    )
    LlmCostTracker::Call.last
  end

  def price_claude_opus6
    LlmCostTracker.configuration.pricing.overrides = { "anthropic/claude-opus-6" => { input: 5.0, output: 25.0 } }
    LlmCostTracker::Pricing::Registry.reset!
  end

  it "prices an Anthropic advisor call recorded before the advisor model had rates" do
    call = record_anthropic(model: "claude-sonnet-4-6", usage: {
                              input_tokens: 2_000, output_tokens: 300,
                              iterations: [{ type: "advisor_message", model: "claude-opus-6",
                                             input_tokens: 1_500, output_tokens: 1_000 }]
                            })
    # Anthropic: Sonnet 4.6 $3 / $15 per MTok; advisor-tool#usage-and-billing bills the advisor at its own rates.
    expect([call.total_cost, call.cost_status]).to eq([0.0105, "partial"])

    price_claude_opus6

    expect(described_class.call.to_h).to eq(examined: 1, recomputed: 1, still_unknown: 0)
    expect([call.reload.total_cost, call.cost_status]).to eq([0.043, "complete"])
    expect(call.line_items.find_by(kind: "model_iteration")).to have_attributes(cost: 0.0325, cost_status: "complete")
  end

  it "prices a billed Anthropic fallback attempt recorded before its model had rates" do
    call = record_anthropic(
      model: "claude-opus-5", stop_reason: "refusal", refusal_category: "general_harms",
      usage: { input_tokens: 5_000, output_tokens: 0, iterations: [
        { type: "message", model: "claude-opus-6", input_tokens: 5_000, output_tokens: 700 },
        { type: "fallback_message", model: "claude-opus-5", input_tokens: 5_000, output_tokens: 0 }
      ] }
    )
    expect([call.total_cost, call.cost_status]).to eq([0, "partial"])

    price_claude_opus6

    expect(described_class.call.to_h).to eq(examined: 1, recomputed: 1, still_unknown: 0)
    # refusals-and-fallback#billing-and-rate-limits: the attempt that produced output is billed (5,000 x $5 + 700 x
    # $25); Opus 5's general_harms refusal before any output is not.
    expect([call.reload.total_cost, call.cost_status]).to eq([0.0425, "complete"])
  end

  it "does not reprice a call with a priced web search once its model has no rates" do
    price_claude_opus6
    call = record_anthropic(model: "claude-opus-6", usage: {
                              input_tokens: 10_000, output_tokens: 1_000, server_tool_use: { web_search_requests: 2 }
                            })
    # Anthropic: web search $10 per 1,000 searches, on top of the $5 / $25 per MTok override.
    expect([call.total_cost, call.cost_status]).to eq([0.095, "complete"])
    LlmCostTracker.configuration.pricing.overrides = {}
    LlmCostTracker::Pricing::Registry.reset!

    result = described_class.call(scope: described_class.reprice_scope(1.hour.ago..), reprice: true)

    expect(result.to_h).to eq(examined: 1, recomputed: 0, still_unknown: 1)
    expect([call.reload.total_cost, call.cost_status]).to eq([0.095, "complete"])
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
