# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Billing::ServiceCharge do
  it "keeps canonical service charge keys as symbols" do
    charge = described_class.build(
      component: :web_search_request,
      quantity: 2,
      cost: "0.02",
      pricing_basis: :provider_usage,
      price_source: :bundled
    )

    expect(charge.component).to eq(:web_search_request)
    expect(charge.unit).to eq(:request)
    expect(charge.pricing_basis).to eq(:provider_usage)
    expect(charge.price_source).to eq(:bundled)
  end

  it "rejects unknown string components" do
    expect do
      described_class.build(component: "missing_component", quantity: 1)
    end.to raise_error(LlmCostTracker::Error, /Unknown billing component/)
  end

  it "rejects partial service charge cost status" do
    expect do
      described_class.build(
        component: :web_search_request,
        quantity: 1,
        cost_status: LlmCostTracker::Billing::CostStatus::PARTIAL
      )
    end.to raise_error(LlmCostTracker::Error, /Invalid service charge cost_status/)
  end
end
