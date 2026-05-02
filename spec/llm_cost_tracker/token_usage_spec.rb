# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::TokenUsage do
  it "returns persisted token columns" do
    usage = described_class.build(
      input_tokens: 10,
      cache_read_input_tokens: 2,
      cache_write_input_tokens: 3,
      cache_write_1h_input_tokens: 4,
      audio_input_tokens: 7,
      output_tokens: 5,
      audio_output_tokens: 8,
      hidden_output_tokens: 6
    )

    expect(usage.to_h).to eq(
      input_tokens: 10,
      cache_read_input_tokens: 2,
      cache_write_input_tokens: 3,
      cache_write_1h_input_tokens: 4,
      audio_input_tokens: 7,
      output_tokens: 5,
      audio_output_tokens: 8,
      total_tokens: 39,
      hidden_output_tokens: 6
    )
  end
end
