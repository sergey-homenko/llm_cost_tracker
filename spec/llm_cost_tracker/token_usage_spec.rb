# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Usage::TokenUsage do
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
      image_input_tokens: 0,
      output_tokens: 5,
      audio_output_tokens: 8,
      image_output_tokens: 0,
      total_tokens: 39,
      hidden_output_tokens: 6
    )
  end

  it "builds from public token keys" do
    usage = described_class.build_from_tokens(
      input_tokens: 10,
      "cache_read_input_tokens" => 2,
      "cache_write_input_tokens" => 3,
      "cache_write_extended_input_tokens" => 4,
      "audio_input_tokens" => 7,
      "output_tokens" => 5,
      "audio_output_tokens" => 8,
      hidden_output_tokens: 6
    )

    expect(usage.to_h).to eq(
      input_tokens: 10,
      cache_read_input_tokens: 2,
      cache_write_input_tokens: 3,
      cache_write_extended_input_tokens: 4,
      audio_input_tokens: 7,
      image_input_tokens: 0,
      output_tokens: 5,
      audio_output_tokens: 8,
      image_output_tokens: 0,
      total_tokens: 39,
      hidden_output_tokens: 6
    )
  end

  it "builds from string keys for JSON-style manual input" do
    usage = described_class.build_from_tokens("input_tokens" => 100, "output_tokens" => 50)

    expect(usage.input_tokens).to eq(100)
    expect(usage.output_tokens).to eq(50)
  end

  it "raises when given a non-hashable input" do
    expect { described_class.build_from_tokens(42) }.to raise_error(ArgumentError, /must be a Hash/)
  end

  it "raises when no recognized keys are present so provider response shapes are caught" do
    expect do
      described_class.build_from_tokens(prompt_tokens: 10, completion_tokens: 5)
    end.to raise_error(ArgumentError, /raw provider response/)
  end

  it "raises on a typo'd key mixed with recognized ones instead of silently dropping it" do
    expect do
      described_class.build_from_tokens(input_tokens: 10, outpt_tokens: 3)
    end.to raise_error(ArgumentError, /outpt_tokens/)
  end

  it "builds a zero usage from an empty hash" do
    usage = described_class.build_from_tokens({})

    expect(usage.total_tokens).to eq(0)
  end
end
