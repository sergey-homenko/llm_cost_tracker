# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::PriceSync::Validator do
  let(:validator) { described_class.new }

  def raw_price(input:, output:)
    LlmCostTracker::PriceSync::RawPrice.new(
      model: "gpt-4o",
      provider: "openai",
      input: input,
      output: output,
      cached_input: nil,
      cache_read_input: nil,
      cache_creation_input: nil,
      source: :litellm,
      source_version: "litellm-v1",
      fetched_at: "2026-04-22T00:00:00Z"
    )
  end

  it "rejects impossible prices" do
    result = validator.validate_batch(
      { "gpt-4o" => raw_price(input: 150.0, output: 10.0) },
      existing_registry: {}
    )

    expect(result.accepted).to eq({})
    expect(result.rejected.map(&:reason)).to eq(["input > $100.0/1M"])
  end

  it "flags large relative changes while still accepting them" do
    result = validator.validate_batch(
      { "gpt-4o" => raw_price(input: 12.5, output: 40.0) },
      existing_registry: { "gpt-4o" => { "input" => 2.5, "output" => 10.0 } }
    )

    expect(result.accepted.keys).to eq(["gpt-4o"])
    expect(result.flagged.map(&:reason)).to eq(["price changed >3.0x"])
  end

  it "allows explicit validator overrides to skip relative-change checks" do
    result = validator.validate_batch(
      { "gpt-4o" => raw_price(input: 12.5, output: 40.0) },
      existing_registry: {
        "gpt-4o" => {
          "input" => 2.5,
          "output" => 10.0,
          "_validator_override" => ["skip_relative_change"]
        }
      }
    )

    expect(result.flagged).to eq([])
    expect(result.rejected).to eq([])
    expect(result.accepted.keys).to eq(["gpt-4o"])
  end
end
