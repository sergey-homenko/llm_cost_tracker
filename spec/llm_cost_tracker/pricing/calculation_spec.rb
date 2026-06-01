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
end
