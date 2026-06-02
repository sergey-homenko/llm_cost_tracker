# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Usage::Catalog do
  it "keeps token-priced dimensions aligned with Usage::TokenUsage" do
    token_keys = described_class.token_priced.map(&:token_key)
    missing = token_keys - LlmCostTracker::Usage::TokenUsage.members

    expect(missing).to be_empty
  end

  it "exposes cost_key for every token-priced dimension" do
    described_class.token_priced.each do |dimension|
      expect(dimension.cost_key).to be_a(Symbol)
    end
  end

  it "has unique dimension keys" do
    keys = described_class.all.map(&:key)

    expect(keys).to eq(keys.uniq)
  end

  it "loads identity fields from the YAML registry" do
    grounding = described_class.fetch("grounding_request")

    expect(grounding).to have_attributes(
      kind: "grounding_request",
      direction: "neither",
      modality: "text",
      cache_state: "none",
      unit: "request",
      token_key: nil,
      cost_key: nil,
      rate_basis: "per_1k_requests"
    )

    input = described_class.fetch("input")
    expect(input).to have_attributes(token_key: :input_tokens, cost_key: :input_cost)
  end

  it "defaults the rate_basis from the unit when YAML omits the field" do
    expect(described_class.fetch("input").rate_basis).to eq("per_million_tokens")
    expect(described_class.fetch("container_session").rate_basis).to eq("per_session")
    expect(described_class.fetch("code_execution_hour").rate_basis).to eq("per_hour")
  end

  it "uses only rate_basis values that the pricing engine knows how to quantify" do
    described_class.all.each do |dimension|
      expect(LlmCostTracker::Pricing::RATE_BASIS_QUANTITIES).to have_key(dimension.rate_basis),
        -> { "#{dimension.key} declares unknown rate_basis #{dimension.rate_basis.inspect}" }
    end
  end
end
