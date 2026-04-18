# frozen_string_literal: true

require "json"
require "spec_helper"
require "tempfile"

RSpec.describe LlmCostTracker::Pricing do
  describe ".cost_for" do
    it "calculates cost for a known model" do
      result = described_class.cost_for(
        model: "gpt-4o",
        input_tokens: 1_000,
        output_tokens: 500
      )

      expect(result).to be_a(LlmCostTracker::Cost)
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

    it "matches OpenRouter-style provider-prefixed model names" do
      result = described_class.cost_for(
        model: "openai/gpt-4o-mini",
        input_tokens: 1_000_000,
        output_tokens: 0
      )

      expect(result).not_to be_nil
      expect(result[:input_cost]).to eq(0.15)
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

    it "loads local JSON pricing files ahead of built-in prices" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write(JSON.generate("models" => {
                                   "gpt-4o" => { "input" => 9.0, "output" => 10.0 }
                                 }))
        file.close

        LlmCostTracker.configure do |c|
          c.prices_file = file.path
        end

        result = described_class.cost_for(
          model: "gpt-4o",
          input_tokens: 1_000_000,
          output_tokens: 0
        )

        expect(result[:input_cost]).to eq(9.0)
      end
    end

    it "keeps Ruby pricing overrides ahead of local price files" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write(JSON.generate("models" => {
                                   "my-custom-model" => { "input" => 9.0, "output" => 10.0 }
                                 }))
        file.close

        LlmCostTracker.configure do |c|
          c.prices_file = file.path
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

    it "loads local YAML pricing files" do
      Tempfile.create(["llm-prices", ".yml"]) do |file|
        file.write(<<~YAML)
          models:
            yaml-model:
              input: 3.0
              output: 4.0
        YAML
        file.close

        LlmCostTracker.configure do |c|
          c.prices_file = file.path
        end

        result = described_class.cost_for(
          model: "yaml-model",
          input_tokens: 1_000_000,
          output_tokens: 1_000_000
        )

        expect(result[:input_cost]).to eq(3.0)
        expect(result[:output_cost]).to eq(4.0)
      end
    end

    it "raises a readable error for invalid local price files" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write("{")
        file.close

        LlmCostTracker.configure do |c|
          c.prices_file = file.path
        end

        expect do
          described_class.cost_for(model: "gpt-4o", input_tokens: 1, output_tokens: 1)
        end.to raise_error(LlmCostTracker::Error, /Unable to load prices_file/)
      end
    end

    it "uses normalized pricing overrides for provider-prefixed models" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "deepseek-chat" => { input: 0.27, output: 1.10 }
        }
      end

      result = described_class.cost_for(
        model: "deepseek/deepseek-chat",
        input_tokens: 1_000_000,
        output_tokens: 1_000_000
      )

      expect(result[:input_cost]).to eq(0.27)
      expect(result[:output_cost]).to eq(1.1)
    end
  end

  describe ".lookup" do
    it "memoizes sorted price keys safely under concurrent lookup" do
      %i[@sorted_price_keys @sorted_price_keys_table].each do |ivar|
        described_class.remove_instance_variable(ivar) if described_class.instance_variable_defined?(ivar)
      end

      table = {
        "gpt-4" => { input: 30.0, output: 60.0 },
        "gpt-4o" => { input: 2.5, output: 10.0 }
      }

      results = 10.times.map do
        Thread.new { described_class.send(:sorted_price_keys, table) }
      end.map(&:value)

      expect(results.map(&:object_id).uniq.size).to eq(1)
      expect(results.first).to eq(%w[gpt-4o gpt-4])
    end
  end

  describe ".metadata" do
    it "exposes built-in pricing metadata" do
      expect(described_class.metadata).to include("updated_at" => "2026-04-18")
      expect(described_class.metadata.fetch("source_urls")).not_to be_empty
    end
  end
end
