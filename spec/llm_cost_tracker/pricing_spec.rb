# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Pricing do
  describe ".cost_for" do
    it "calculates cost for a known model" do
      result = described_class.cost_for(
        model: "gpt-4o",
        input_tokens: 1_000,
        output_tokens: 500
      )

      expect(result[:input_cost]).to be > 0
      expect(result[:output_cost]).to be > 0
      expect(result[:total_cost]).to eq(result[:input_cost] + result[:output_cost])
      expect(result[:currency]).to eq("USD")
    end

    it "returns nil for unknown models" do
      result = described_class.cost_for(
        model: "totally-unknown-model",
        input_tokens: 100,
        output_tokens: 50
      )

      expect(result).to be_nil
    end

    it "fuzzy-matches versioned model names" do
      result = described_class.cost_for(
        model: "gpt-4o-2024-08-06",
        input_tokens: 1_000_000,
        output_tokens: 0
      )

      expect(result).not_to be_nil
      expect(result[:input_cost]).to eq(2.5)
    end

    it "prefers the longest fuzzy match for overlapping model names" do
      result = described_class.cost_for(
        model: "gpt-5.2-2026-01-01",
        input_tokens: 1_000_000,
        output_tokens: 0
      )

      expect(result[:input_cost]).to eq(1.75)
    end

    it "prices cached OpenAI input tokens at the cached rate" do
      result = described_class.cost_for(
        model: "gpt-5-mini",
        input_tokens: 1_000_000,
        cached_input_tokens: 400_000,
        output_tokens: 0
      )

      expect(result[:input_cost]).to eq(0.15)
      expect(result[:cached_input_cost]).to eq(0.01)
      expect(result[:total_cost]).to eq(0.16)
    end

    it "prices Anthropic cache read and creation tokens separately" do
      result = described_class.cost_for(
        model: "claude-sonnet-4-6",
        input_tokens: 100_000,
        cache_read_input_tokens: 200_000,
        cache_creation_input_tokens: 300_000,
        output_tokens: 10_000
      )

      expect(result[:input_cost]).to eq(0.3)
      expect(result[:cache_read_input_cost]).to eq(0.06)
      expect(result[:cache_creation_input_cost]).to eq(1.125)
      expect(result[:output_cost]).to eq(0.15)
      expect(result[:total_cost]).to eq(1.635)
    end

    it "uses current Gemini 2.5 Flash standard pricing" do
      result = described_class.cost_for(
        model: "gemini-2.5-flash",
        input_tokens: 1_000_000,
        output_tokens: 1_000_000
      )

      expect(result[:input_cost]).to eq(0.3)
      expect(result[:output_cost]).to eq(2.5)
    end

    it "uses pricing overrides when configured" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "my-custom-model" => { input: 1.0, output: 2.0 }
        }
      end

      result = described_class.cost_for(
        model: "my-custom-model",
        input_tokens: 1_000_000,
        output_tokens: 1_000_000
      )

      expect(result[:input_cost]).to eq(1.0)
      expect(result[:output_cost]).to eq(2.0)
    end
  end
end
