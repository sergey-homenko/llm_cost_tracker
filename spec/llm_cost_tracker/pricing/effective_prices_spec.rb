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

  it "derives a cache rate from the input ratio and names it with the mode when only the mode input rate is set" do
    prices = { "input" => 1.0, "output" => 2.0, "cache_read_input" => 0.1, "batch_input" => 0.5 }

    rates = described_class.call(usage: usage, quantities: usage.priced_quantities, prices: prices, pricing_mode: "batch")

    expect(rates["input"].amount).to eq(0.5)
    expect(rates["input"].key).to eq("batch_input")
    expect(rates["cache_read_input"].amount).to eq(0.05)
    expect(rates["cache_read_input"].key).to eq("batch_cache_read_input")
  end

  it "names the mode-prefixed key it actually read" do
    prices = { "input" => 1.0, "output" => 2.0, "cache_read_input" => 0.1, "batch_cache_read_input" => 0.07 }

    rates = described_class.call(usage: usage, quantities: usage.priced_quantities, prices: prices, pricing_mode: "batch")

    expect(rates["cache_read_input"].key).to eq("batch_cache_read_input")
    expect(rates["cache_read_input"].amount).to eq(0.07)
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

    expect(rates["cache_read_input"].amount).to eq(0.05)
    expect(rates["cache_read_input"].key).to eq("data_residency_batch_cache_read_input")
  end

  it "returns nil for the derived rate when the standard cache rate is missing" do
    prices = { "input" => 1.0, "output" => 2.0, "batch_input" => 0.5 }

    rates = described_class.call(usage: usage, quantities: usage.priced_quantities, prices: prices, pricing_mode: "batch")

    expect(rates["cache_read_input"]).to be_nil
  end

  it "prices cached audio at its own rate, else at cache_read_input, else at the OpenAI input rate" do
    quantities = usage.priced_quantities.merge("audio_cache_read_input" => 10)
    rate_for = lambda do |prices, cache_at_input_rate: []|
      described_class.call(usage: usage, quantities: quantities, prices: prices, pricing_mode: nil,
                           cache_at_input_rate: cache_at_input_rate)["audio_cache_read_input"]
    end

    expect(rate_for.call({ "cache_read_input" => 0.06, "audio_cache_read_input" => 0.3 })).to have_attributes(
      amount: 0.3, key: "audio_cache_read_input"
    )
    expect(rate_for.call({ "cache_read_input" => 0.06 })).to have_attributes(amount: 0.06, key: "cache_read_input")
    expect(rate_for.call({ "input" => 1.0 }, cache_at_input_rate: %w[cache_read_input])).to have_attributes(amount: 1.0, key: "input")
    expect(rate_for.call({ "input" => 1.0 })).to be_nil
  end
end
