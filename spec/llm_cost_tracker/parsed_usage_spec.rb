# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::ParsedUsage do
  it "normalizes missing model identifiers to unknown" do
    usage = described_class.build(
      provider: "custom",
      model: nil,
      input_tokens: 1,
      output_tokens: 2
    )

    expect(usage.model).to eq("unknown")
  end

  it "normalizes blank model identifiers to unknown" do
    usage = described_class.build(
      provider: "custom",
      model: " ",
      input_tokens: 1,
      output_tokens: 2
    )

    expect(usage.model).to eq("unknown")
  end
end
