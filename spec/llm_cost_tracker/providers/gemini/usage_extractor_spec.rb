# frozen_string_literal: true

require "spec_helper"
require "llm_cost_tracker/providers/gemini/usage_extractor"

RSpec.describe LlmCostTracker::Providers::Gemini::UsageExtractor do
  describe ".token_usage" do
    it "splits cache, tool-use prompt, and thoughts out of the regular buckets" do
      result = described_class.token_usage(
        "promptTokenCount" => 100,
        "candidatesTokenCount" => 40,
        "thoughtsTokenCount" => 5,
        "cachedContentTokenCount" => 10,
        "toolUsePromptTokenCount" => 7,
        "totalTokenCount" => 162
      )

      expect(result.input_tokens).to eq(100 - 10 + 7)
      expect(result.output_tokens).to eq(40 + 5)
      expect(result.cache_read_input_tokens).to eq(10)
      expect(result.hidden_output_tokens).to eq(5)
      expect(result.total_tokens).to eq(162)
    end

    it "extracts audio and image modality tokens net of cached modality tokens" do
      result = described_class.token_usage(
        "promptTokenCount" => 200,
        "candidatesTokenCount" => 60,
        "promptTokensDetails" => [{ "modality" => "AUDIO", "tokenCount" => 30 },
                                  { "modality" => "IMAGE", "tokenCount" => 20 }],
        "cacheTokensDetails" => [{ "modality" => "AUDIO", "tokenCount" => 10 }],
        "candidatesTokensDetails" => [{ "modality" => "AUDIO", "tokenCount" => 15 },
                                      { "modality" => "IMAGE", "tokenCount" => 5 }]
      )

      expect(result.audio_input_tokens).to eq(20)
      expect(result.image_input_tokens).to eq(20)
      expect(result.audio_output_tokens).to eq(15)
      expect(result.image_output_tokens).to eq(5)
      expect(result.input_tokens).to eq(200 - 20 - 20)
      expect(result.output_tokens).to eq(60 - 15 - 5)
    end

    it "floors regular buckets at zero when modality tokens exceed the totals" do
      result = described_class.token_usage(
        "promptTokenCount" => 10,
        "candidatesTokenCount" => 5,
        "promptTokensDetails" => [{ "modality" => "AUDIO", "tokenCount" => 50 }]
      )

      expect(result.input_tokens).to eq(0)
      expect(result.output_tokens).to eq(5)
    end
  end
end
