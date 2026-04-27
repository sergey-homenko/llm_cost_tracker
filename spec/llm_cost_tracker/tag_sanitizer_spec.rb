# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::TagSanitizer do
  let(:config) do
    instance_double(
      LlmCostTracker::Configuration,
      max_tag_count: 2,
      max_tag_value_bytesize: 4,
      redacted_tag_keys: %w[api_key access_token]
    )
  end

  it "keeps only the configured number of tags" do
    tags = described_class.call({ first: "1", second: "2", third: "3" }, config: config)

    expect(tags).to eq(first: "1", second: "2")
  end

  it "redacts configured secret-like keys and common variants" do
    tags = described_class.call({ "openai.APIKey" => "sk-secret", accessToken: "token" }, config: config)

    expect(tags["openai.APIKey"]).to eq("[REDACTED]")
    expect(tags[:accessToken]).to eq("[REDACTED]")
  end

  it "truncates large values while preserving small values" do
    tags = described_class.call({ feature: "abcdef", user_id: 42 }, config: config)

    expect(tags[:feature]).to eq("abcd")
    expect(tags[:user_id]).to eq(42)
  end
end
