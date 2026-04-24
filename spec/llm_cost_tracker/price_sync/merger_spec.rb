# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::PriceSync::Merger do
  let(:litellm_result) do
    LlmCostTracker::PriceSync::SourceResult.new(
      prices: [
        LlmCostTracker::PriceSync::RawPrice.new(
          model: "gpt-4o-mini",
          provider: "openai",
          input: 0.15,
          output: 0.6,
          cache_read_input: nil,
          cache_write_input: nil,
          source: :litellm,
          source_version: "litellm-v1",
          fetched_at: "2026-04-22T00:00:00Z"
        )
      ],
      missing_models: [],
      source_version: "litellm-v1"
    )
  end

  let(:openrouter_result) do
    LlmCostTracker::PriceSync::SourceResult.new(
      prices: [
        LlmCostTracker::PriceSync::RawPrice.new(
          model: "gpt-4o-mini",
          provider: "openai",
          input: 0.15,
          output: 0.63,
          cache_read_input: 0.075,
          cache_write_input: nil,
          source: :openrouter,
          source_version: "openrouter-v1",
          fetched_at: "2026-04-22T00:00:00Z"
        )
      ],
      missing_models: [],
      source_version: "openrouter-v1"
    )
  end

  it "keeps the primary source for base pricing and fills missing cache fields from fallbacks" do
    merged, discrepancies = described_class.new.merge(
      litellm: litellm_result,
      openrouter: openrouter_result
    )

    expect(merged.fetch("gpt-4o-mini")).to have_attributes(
      source: :litellm,
      input: 0.15,
      output: 0.6,
      cache_read_input: 0.075
    )
    expect(discrepancies.map { |issue| [issue.model, issue.field] }).to eq([%w[gpt-4o-mini output]])
  end
end
