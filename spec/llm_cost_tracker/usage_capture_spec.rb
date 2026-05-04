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

  it "normalizes capture dimensions at the public capture boundary" do
    usage = described_class.build(
      provider: "custom",
      model: "model",
      token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1, output_tokens: 2),
      provider_project_id: " project-1 ",
      provider_api_key_id: " key-1 ",
      provider_workspace_id: " workspace-1 "
    )

    expect(usage.provider_project_id).to eq("project-1")
    expect(usage.provider_api_key_id).to eq("key-1")
    expect(usage.provider_workspace_id).to eq("workspace-1")
  end

  it "marks batch capture from pricing mode when batch is not explicit" do
    usage = described_class.build(
      provider: "custom",
      model: "model",
      token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1, output_tokens: 2),
      pricing_mode: :batch
    )

    expect(usage.batch).to eq(true)
  end

  it "keeps explicit batch capture ahead of pricing mode" do
    usage = described_class.build(
      provider: "custom",
      model: "model",
      token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1, output_tokens: 2),
      pricing_mode: :batch,
      batch: false
    )

    expect(usage.batch).to eq(false)
  end
end
