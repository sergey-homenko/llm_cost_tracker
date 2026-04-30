# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::TokenUsage do
  it "returns persisted token columns" do
    usage = described_class.build(
      input_tokens: 10,
      cache_read_input_tokens: 2,
      cache_write_input_tokens: 3,
      cache_write_1h_input_tokens: 4,
      output_tokens: 5,
      hidden_output_tokens: 6
    )

    expect(usage.stored_attributes).to eq(
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 24,
      cache_read_input_tokens: 2,
      cache_write_input_tokens: 3,
      cache_write_1h_input_tokens: 4,
      hidden_output_tokens: 6
    )
  end
end
