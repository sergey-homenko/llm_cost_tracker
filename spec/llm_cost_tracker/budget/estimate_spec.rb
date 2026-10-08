# frozen_string_literal: true

require "spec_helper"
require "bigdecimal"
require "llm_cost_tracker/budget/estimate"

RSpec.describe LlmCostTracker::Budget::Estimate do
  before do
    prices = { "small" => BigDecimal("0.5"), "large" => BigDecimal("2") }
    allow(LlmCostTracker::Pricing::Estimator).to receive(:call) { |model:, **| prices[model] }
  end

  it "estimates a single request as both the total and the largest cost" do
    estimate = described_class.for(provider: "openai", model: "large", request: { "input" => "hi" })

    expect(estimate).to have_attributes(total: BigDecimal("2"), largest: BigDecimal("2"))
  end

  it "estimates nothing without a provider, model or request, or for an unpriced model" do
    costs = [
      described_class.for(provider: nil, model: "large", request: {}),
      described_class.for(provider: "openai", model: nil, request: nil),
      described_class.for(provider: "openai", model: "unknown", request: { "input" => "hi" })
    ].map(&:total)

    expect(costs).to all(eq(BigDecimal("0")))
  end

  it "sums the priced entries of a batch request and keeps the largest one" do
    request = {
      "requests" => [
        { "params" => { "model" => "small", "input" => "a" } },
        { "params" => { "model" => "large", "input" => "b" } },
        { "params" => "not a hash" },
        "not an entry"
      ]
    }

    estimate = described_class.for(provider: "openai", model: nil, request: request)

    expect(estimate).to have_attributes(total: BigDecimal("2.5"), largest: BigDecimal("2"))
  end

  it "treats an empty batch as zero and estimates a modelled request whole" do
    empty = described_class.for(provider: "openai", model: nil, request: { "requests" => [] })
    modelled = described_class.for(provider: "openai", model: "small", request: { "requests" => [] })

    expect(empty).to have_attributes(total: BigDecimal("0"), largest: BigDecimal("0"))
    expect(modelled.total).to eq(BigDecimal("0.5"))
  end
end
