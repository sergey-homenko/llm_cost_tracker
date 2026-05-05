# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Billing::CostStatus do
  let(:token_usage) { LlmCostTracker::TokenUsage.build(input_tokens: 0, output_tokens: 0) }

  def service_charge(component: :web_search_request, quantity: 1, cost: nil, cost_status: nil)
    LlmCostTracker::Billing::ServiceCharge.build(
      component: component,
      quantity: quantity,
      cost: cost,
      cost_status: cost_status
    )
  end

  it "ignores non-billable service charges" do
    status = described_class.call(
      token_usage: token_usage,
      usage_source: :manual,
      token_cost: nil,
      service_charges: [
        service_charge(quantity: 0, cost_status: described_class::UNKNOWN)
      ],
      total_cost: nil
    )

    expect(status).to eq(described_class::FREE)
  end

  it "stops scanning service charges after priced and unpriced usage are both known" do
    status = described_class.call(
      token_usage: token_usage,
      usage_source: :manual,
      token_cost: nil,
      service_charges: [
        service_charge(cost: 0.01),
        service_charge(cost_status: described_class::UNKNOWN),
        service_charge(cost: 0.02)
      ],
      total_cost: 0.01
    )

    expect(status).to eq(described_class::PARTIAL)
  end

  it "treats nil total cost with no billable usage as free" do
    status = described_class.call(
      token_usage: token_usage,
      usage_source: :manual,
      token_cost: nil,
      service_charges: [],
      total_cost: nil
    )

    expect(status).to eq(described_class::FREE)
  end

  it "marks token pricing partial when some token components were priced and others were not" do
    billable_usage = LlmCostTracker::TokenUsage.build(input_tokens: 1_000, output_tokens: 1_000)

    status = described_class.call(
      token_usage: billable_usage,
      usage_source: :response,
      token_cost: { input_cost: 0.01, total_cost: 0.01 },
      token_pricing_partial: true,
      service_charges: [],
      total_cost: 0.01
    )

    expect(status).to eq(described_class::PARTIAL)
  end
end
