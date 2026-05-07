# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::TokenUsage do
  it "returns persisted token columns" do
    usage = described_class.build(
      input_tokens: 10,
      cache_read_input_tokens: 2,
      cache_write_input_tokens: 3,
      cache_write_extended_input_tokens: 4,
      audio_input_tokens: 7,
      output_tokens: 5,
      audio_output_tokens: 8,
      hidden_output_tokens: 6
    )

    expect(usage.to_h).to eq(
      input_tokens: 10,
      cache_read_input_tokens: 2,
      cache_write_input_tokens: 3,
      cache_write_extended_input_tokens: 4,
      audio_input_tokens: 7,
      output_tokens: 5,
      audio_output_tokens: 8,
      total_tokens: 39,
      hidden_output_tokens: 6
    )
  end

  it "builds from public token component keys" do
    usage = described_class.build_from_tokens(
      input: 10,
      cache_read_input: 2,
      cache_write_input: 3,
      cache_write_extended_input: 4,
      audio_input: 7,
      output: 5,
      audio_output: 8,
      hidden_output: 6
    )

    expect(usage.to_h).to eq(
      input_tokens: 10,
      cache_read_input_tokens: 2,
      cache_write_input_tokens: 3,
      cache_write_extended_input_tokens: 4,
      audio_input_tokens: 7,
      output_tokens: 5,
      audio_output_tokens: 8,
      total_tokens: 39,
      hidden_output_tokens: 6
    )
  end

  it "builds from string keys for JSON-style manual input" do
    usage = described_class.build_from_tokens("input" => 100, "output" => 50)

    expect(usage.input_tokens).to eq(100)
    expect(usage.output_tokens).to eq(50)
  end
end
