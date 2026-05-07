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
      cost_status: LlmCostTracker::Billing::CostStatus::COMPLETE,
      pricing_basis: "rate_table",
      price_key: "input",
      details: {}
    )

    costs = helper.call_line_item_costs_by_component(call)

    expect(costs).to include(input: BigDecimal("0.0025"))
  end
end
