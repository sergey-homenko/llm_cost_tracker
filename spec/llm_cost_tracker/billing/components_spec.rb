# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Billing::Components do
  it "keeps token-priced components aligned with TokenUsage" do
    token_keys = described_class::TOKEN_PRICED.map(&:token_key)
    missing = token_keys - LlmCostTracker::TokenUsage.members

    expect(missing).to be_empty
  end

  it "keeps token-priced cost keys aligned with the call schema" do
    cost_keys = described_class::TOKEN_PRICED.map(&:cost_key)
    missing = cost_keys.map(&:to_s) - LlmCostTracker::Ledger::Schema::Calls::CURRENT_SCHEMA_COLUMNS

    expect(missing).to be_empty
  end

  it "has unique component keys" do
    keys = described_class::REGISTRY.map(&:key)

    expect(keys).to eq(keys.uniq)
  end
end
