# frozen_string_literal: true

require "spec_helper"

require_relative "../dummy/config/environment"

RSpec.describe LlmCostTracker::TokenUsageHelper do
  include_context "with mounted llm cost tracker engine"

  let(:helper) do
    Class.new { include LlmCostTracker::TokenUsageHelper }.new
  end

  it "matches stored line items (strings) against component metadata (symbols)" do
    call = create_call(input_tokens: 1_000, output_tokens: 500, total_cost: BigDecimal("0.0075"))
    LlmCostTracker::CallLineItem.create!(
      llm_cost_tracker_call_id: call.id,
      position: 0,
      kind: "text_token",
      direction: "input",
      modality: "text",
      cache_state: "none",
      unit: "token",
      quantity: 1_000,
      rate_amount: BigDecimal("2.5"),
      rate_quantity: BigDecimal("1000000"),
      cost: BigDecimal("0.0025"),
      currency: "USD",
      cost_status: LlmCostTracker::Charges::CostStatus::COMPLETE,
      pricing_basis: "rate_table",
      price_key: "input",
      details: {}
    )

    costs = helper.call_line_item_costs_by_component(call)

    expect(costs).to include("input" => BigDecimal("0.0025"))
  end

  it "adds cached audio line items to the cache read component and skips service lines" do
    call = create_call(input_tokens: 0, output_tokens: 0, cache_read_input_tokens: 2_000)
    [
      %w[text_token input text read token 0.00006],
      %w[audio_token input audio read token 0.0003],
      %w[web_search_request neither text none request 0.01]
    ].each_with_index do |(kind, direction, modality, cache_state, unit, cost), position|
      LlmCostTracker::CallLineItem.create!(
        llm_cost_tracker_call_id: call.id, position: position, kind: kind, direction: direction, modality: modality,
        cache_state: cache_state, unit: unit, quantity: 1, cost: BigDecimal(cost), currency: "USD",
        cost_status: LlmCostTracker::Charges::CostStatus::COMPLETE, details: {}
      )
    end

    expect(helper.call_line_item_costs_by_component(call)).to eq("cache_read_input" => BigDecimal("0.00036"))
  end
end
