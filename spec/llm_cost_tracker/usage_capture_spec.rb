# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::UsageCapture do
  it "normalizes missing model identifiers to unknown" do
    usage = described_class.build(
      provider: "custom",
      model: nil,
      token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1, output_tokens: 2)
    )

    expect(usage.model).to eq("unknown")
  end

  it "normalizes blank model identifiers to unknown" do
    usage = described_class.build(
      provider: "custom",
      model: " ",
      token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1, output_tokens: 2)
    )

    expect(usage.model).to eq("unknown")
  end
end
