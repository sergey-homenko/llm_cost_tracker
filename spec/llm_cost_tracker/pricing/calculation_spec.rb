# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Pricing::Calculation do
  it "prices a token line item at the exact per-million rate" do
    LlmCostTracker.configure do |c|
      c.pricing_overrides = { "demo-token" => { "input" => 2.5 } }
    end

    line_item = LlmCostTracker::Charges::LineItem.build(dimension_key: "input", quantity: 1_234_567)
    calculation = described_class.for(
      provider: "demo", model: "demo-token",
      tokens: LlmCostTracker::Usage::TokenUsage.build(input_tokens: 1_234_567, output_tokens: 0),
      line_items: [line_item], pricing_mode: nil
    )

    priced = calculation.priced_line_items.find(&:token?)
    expect(priced.cost).to eq(BigDecimal("3.0864175"))
    expect(priced.rate_quantity).to eq(BigDecimal(1_000_000))
    expect(priced.cost_status).to eq(LlmCostTracker::Charges::CostStatus::COMPLETE)
  end

  it "ignores a token-unit line item passed as a service line so token cost is not double-counted" do
    LlmCostTracker.configure { |c| c.pricing_overrides = { "dup-model" => { "input" => 2.0 } } }
    token_line = LlmCostTracker::Charges::LineItem.build(
      kind: "input", direction: "input", modality: "text", cache_state: "none",
      unit: "token", quantity: 1_000_000, dimension_key: "input"
    )
    calculation = described_class.for(
      provider: "custom", model: "dup-model",
      tokens: { input_tokens: 1_000_000 }, pricing_mode: nil, line_items: [token_line]
    )

    expect(calculation.cost.total).to eq(BigDecimal("2.0"))
    expect(calculation.priced_line_items.count(&:token?)).to eq(1)
  end
end
