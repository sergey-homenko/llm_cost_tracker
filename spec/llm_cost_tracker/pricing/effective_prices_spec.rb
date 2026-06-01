# frozen_string_literal: true

require "spec_helper"
require "llm_cost_tracker/pricing/effective_prices"
require "llm_cost_tracker/usage/token_usage"

RSpec.describe LlmCostTracker::Pricing::EffectivePrices do
  let(:usage) do
    LlmCostTracker::Usage::TokenUsage.build(
      input_tokens: 100,
      output_tokens: 200,
      cache_read_input_tokens: 50
    )
  end

  it "derives a cache rate from the input ratio when only the mode-prefixed input rate is set" do
    prices = { "input" => 1.0, "output" => 2.0, "cache_read_input" => 0.1, "batch_input" => 0.5 }

    rates = described_class.call(usage: usage, quantities: usage.priced_quantities, prices: prices, pricing_mode: "batch")

    expect(rates["input"]).to eq(0.5)
    expect(rates["cache_read_input"]).to eq(0.05)
  end

  it "returns nil for the derived rate when the input base price is zero" do
    prices = { "input" => 0.0, "output" => 2.0, "cache_read_input" => 0.1, "batch_input" => 0.0 }

    rates = described_class.call(usage: usage, quantities: usage.priced_quantities, prices: prices, pricing_mode: "batch")

    expect(rates["cache_read_input"]).to be_nil
  end

  it "returns nil for the derived rate when no permutation finds an input rate" do
    prices = { "input" => 1.0, "output" => 2.0, "cache_read_input" => 0.1 }

    rates = described_class.call(usage: usage, quantities: usage.priced_quantities, prices: prices, pricing_mode: "batch")

    expect(rates["cache_read_input"]).to be_nil
  end

  it "permutes compound modes when deriving cache rates from a flipped registry key order" do
    prices = {
      "input" => 1.0,
      "output" => 2.0,
      "cache_read_input" => 0.1,
      "data_residency_batch_input" => 0.5
    }

    rates = described_class.call(usage: usage, quantities: usage.priced_quantities, prices: prices, pricing_mode: "batch_data_residency")

    expect(rates["cache_read_input"]).to eq(0.05)
  end

  it "returns nil for the derived rate when the standard cache rate is missing" do
    prices = { "input" => 1.0, "output" => 2.0, "batch_input" => 0.5 }

    rates = described_class.call(usage: usage, quantities: usage.priced_quantities, prices: prices, pricing_mode: "batch")

    expect(rates["cache_read_input"]).to be_nil
  end
end
