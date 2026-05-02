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

  it "applies a price rate without rebuilding serialized attributes" do
    charge = described_class.build(
      component: :web_search_request,
      quantity: 2,
      cost_status: LlmCostTracker::Billing::CostStatus::UNKNOWN,
      pricing_basis: :provider_usage,
      source_key: "usage.server_tool_use.web_search_requests"
    )

    priced = charge.apply_rate(
      amount: BigDecimal("10.0"),
      quantity: BigDecimal("1000"),
      currency: "USD",
      source: :bundled,
      source_key: "service_charges.anthropic.web_search_request",
      source_version: "1.0.0"
    )

    expect(priced.cost_status).to eq(LlmCostTracker::Billing::CostStatus::COMPLETE)
    expect(priced.cost).to eq(BigDecimal("0.02"))
    expect(priced.rate_amount).to eq(BigDecimal("10.0"))
    expect(priced.rate_quantity).to eq(BigDecimal("1000"))
    expect(priced.price_key).to eq("service_charges.anthropic.web_search_request")
    expect(priced.price_source).to eq(:bundled)
    expect(priced.price_source_version).to eq("1.0.0")
    expect(priced.source_key).to eq("usage.server_tool_use.web_search_requests")
  end

  it "marks zero-quantity applied rates as free" do
    charge = described_class.build(
      component: :web_search_request,
      quantity: 0,
      cost_status: LlmCostTracker::Billing::CostStatus::UNKNOWN
    )

    priced = charge.apply_rate(
      amount: BigDecimal("10.0"),
      quantity: BigDecimal("1000"),
      currency: "USD",
      source: :bundled,
      source_key: "service_charges.anthropic.web_search_request",
      source_version: "1.0.0"
    )

    expect(priced.cost_status).to eq(LlmCostTracker::Billing::CostStatus::FREE)
    expect(priced.cost).to eq(BigDecimal("0"))
  end
end
