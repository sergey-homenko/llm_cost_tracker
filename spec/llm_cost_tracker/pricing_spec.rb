# frozen_string_literal: true

require "json"
require "spec_helper"
require "tempfile"

RSpec.describe LlmCostTracker::Pricing do
  describe ".cost_for" do
    it "calculates cost for a known model" do
      result = described_class.cost_for(
        provider: "openai",
        model: "gpt-4o",
        input_tokens: 1_000,
        output_tokens: 500
      )

      expect(result).to be_a(LlmCostTracker::Cost)
      expect(result.input_cost).to be > 0
      expect(result.output_cost).to be > 0
      expect(result.total_cost).to eq(result.input_cost + result.output_cost)
      expect(result.currency).to eq("USD")
    end

    it "returns nil for unknown models" do
      result = described_class.cost_for(
        provider: "openai",
        model: "totally-unknown-model",
        input_tokens: 100,
        output_tokens: 50
      )

      expect(result).to be_nil
    end

    it "fuzzy-matches dated snapshot suffixes to the base model" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = { "demo-base" => { input: 1.0, output: 2.0 } }
      end

      result = described_class.cost_for(
        provider: "custom",
        model: "demo-base-2026-01-01",
        input_tokens: 1_000_000,
        output_tokens: 0
      )

      expect(result.input_cost).to eq(1.0)
    end

    it "matches provider-prefixed model names from gateways" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = { "demo-mini" => { input: 0.1, output: 0.4 } }
      end

      result = described_class.cost_for(
        provider: "demogateway",
        model: "demo/demo-mini",
        input_tokens: 1_000_000,
        output_tokens: 0
      )

      expect(result.input_cost).to eq(0.1)
    end

    it "matches unique provider-qualified prices for gateway model names" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = { "upstream/demo-mini" => { input: 0.1, output: 0.4 } }
      end

      result = described_class.cost_for(
        provider: "gateway",
        model: "demo-mini",
        input_tokens: 1_000_000,
        output_tokens: 0
      )

      expect(result.input_cost).to eq(0.1)
    end

    it "does not match ambiguous provider-qualified prices by model name alone" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "first/demo-mini" => { input: 0.1, output: 0.4 },
          "second/demo-mini" => { input: 0.2, output: 0.8 }
        }
      end

      result = described_class.cost_for(
        provider: "gateway",
        model: "demo-mini",
        input_tokens: 1_000_000,
        output_tokens: 0
      )

      expect(result).to be_nil
    end

    it "prefers the longest fuzzy match for overlapping model names" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "demo-family" => { input: 5.0, output: 10.0 },
          "demo-family-mini" => { input: 0.5, output: 1.0 }
        }
      end

      result = described_class.cost_for(
        provider: "custom",
        model: "demo-family-mini-2026-01-01",
        input_tokens: 1_000_000,
        output_tokens: 0
      )

      expect(result.input_cost).to eq(0.5)
    end

    it "does not fuzzy-match unknown model families to older prices" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = { "demo-1.0" => { input: 1.0, output: 2.0 } }
      end

      expect(
        described_class.cost_for(provider: "custom", model: "demo-2.0", input_tokens: 1_000_000, output_tokens: 0)
      ).to be_nil
    end

    it "does not fuzzy-match unknown model variants to base prices" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "base-model" => { input: 1.0, output: 2.0 }
        }
      end

      result = described_class.cost_for(
        provider: "custom",
        model: "base-model-pro",
        input_tokens: 1_000_000,
        output_tokens: 0
      )

      expect(result).to be_nil
    end

    it "prices cache-read input tokens separately from regular input" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "demo-cached" => { input: 0.25, output: 2.0, cache_read_input: 0.025 }
        }
      end

      result = described_class.cost_for(
        provider: "custom",
        model: "demo-cached",
        input_tokens: 600_000,
        cache_read_input_tokens: 400_000,
        output_tokens: 0
      )

      expect(result.input_cost).to eq(0.15)
      expect(result.cache_read_input_cost).to eq(0.01)
      expect(result.total_cost).to eq(0.16)
    end

    it "prices cache read and write tokens separately and sums into total" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "demo-cache-rw" => {
            input: 3.0,
            output: 15.0,
            cache_read_input: 0.3,
            cache_write_input: 3.75
          }
        }
      end

      result = described_class.cost_for(
        provider: "custom",
        model: "demo-cache-rw",
        input_tokens: 100_000,
        cache_read_input_tokens: 200_000,
        cache_write_input_tokens: 300_000,
        output_tokens: 10_000
      )

      expect(result.input_cost).to eq(0.3)
      expect(result.cache_read_input_cost).to eq(0.06)
      expect(result.cache_write_input_cost).to eq(1.125)
      expect(result.output_cost).to eq(0.15)
      expect(result.total_cost).to be_within(0.0001).of(
        result.input_cost + result.cache_read_input_cost +
          result.cache_write_input_cost + result.output_cost
      )
    end

    it "uses pricing overrides when configured" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "my-custom-model" => { input: 1.0, output: 2.0 }
        }
      end

      result = described_class.cost_for(
        provider: "custom",
        model: "my-custom-model",
        input_tokens: 1_000_000,
        output_tokens: 1_000_000
      )

      expect(result.input_cost).to eq(1.0)
      expect(result.output_cost).to eq(2.0)
    end

    it "uses mode-specific price keys when pricing_mode is provided" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "batchable-model" => {
            input: 1.0,
            output: 2.0,
            batch_input: 0.5,
            batch_output: 1.0
          }
        }
      end

      result = described_class.cost_for(
        provider: "custom",
        model: "batchable-model",
        input_tokens: 1_000_000,
        output_tokens: 1_000_000,
        pricing_mode: :batch
      )

      expect(result.input_cost).to eq(0.5)
      expect(result.output_cost).to eq(1.0)
      expect(result.total_cost).to eq(1.5)
    end

    it "falls back to standard price keys for missing mode-specific keys" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "mixed-mode-model" => {
            input: 1.0,
            output: 2.0,
            batch_input: 0.5
          }
        }
      end

      result = described_class.cost_for(
        provider: "custom",
        model: "mixed-mode-model",
        input_tokens: 1_000_000,
        output_tokens: 1_000_000,
        pricing_mode: :batch
      )

      expect(result.input_cost).to eq(0.5)
      expect(result.output_cost).to eq(2.0)
      expect(result.total_cost).to eq(2.5)
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
          provider: "openai",
          model: "gpt-4o",
          input_tokens: 1_000_000,
          output_tokens: 0
        )

        expect(result.input_cost).to eq(9.0)
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
          provider: "custom",
          model: "my-custom-model",
          input_tokens: 1_000_000,
          output_tokens: 1_000_000
        )

        expect(result.input_cost).to eq(1.0)
        expect(result.output_cost).to eq(2.0)
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
          provider: "custom",
          model: "yaml-model",
          input_tokens: 1_000_000,
          output_tokens: 1_000_000
        )

        expect(result.input_cost).to eq(3.0)
        expect(result.output_cost).to eq(4.0)
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
          described_class.cost_for(provider: "openai", model: "gpt-4o", input_tokens: 1, output_tokens: 1)
        end.to raise_error(LlmCostTracker::Error, /Unable to load prices_file/)
      end
    end

    it "prefers provider-specific pricing overrides" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "deepseek-chat" => { input: 0.27, output: 1.10 },
          "deepseek/deepseek-chat" => { input: 0.20, output: 0.90 }
        }
      end

      result = described_class.cost_for(
        provider: "deepseek",
        model: "deepseek-chat",
        input_tokens: 1_000_000,
        output_tokens: 1_000_000
      )

      expect(result.input_cost).to eq(0.2)
      expect(result.output_cost).to eq(0.9)
    end
  end

  describe ".lookup" do
    it "returns consistent sorted keys under concurrent lookup" do
      if described_class.instance_variable_defined?(:@sorted_price_keys_cache)
        described_class.remove_instance_variable(:@sorted_price_keys_cache)
      end

      table = {
        "gpt-4" => { input: 30.0, output: 60.0 },
        "gpt-4o" => { input: 2.5, output: 10.0 }
      }

      results = 10.times.map do
        Thread.new { described_class.send(:sorted_price_keys, table) }
      end.map(&:value)

      expect(results).to all(eq(%w[gpt-4o gpt-4]))
    end
  end

  describe "bundled price snapshot" do
    let(:bundled) { LlmCostTracker::PriceRegistry.builtin_prices }

    it "ships at least one model" do
      expect(bundled.size).to be > 0
    end

    it "uses provider-qualified model keys" do
      expect(bundled.keys).to all(include("/"))
    end

    it "uses positive numeric values for every recognised price field" do
      bundled.each do |model_id, fields|
        fields.each do |field, value|
          field_name = field.to_s
          next unless LlmCostTracker::PriceRegistry::PRICE_KEYS.include?(field_name) ||
                      field_name.match?(/_(input|output)\z/)

          expect(value).to be_a(Numeric), "#{model_id}.#{field} expected Numeric, got #{value.inspect}"
          expect(value).to be > 0, "#{model_id}.#{field} expected positive, got #{value}"
        end
      end
    end

    it "holds the Anthropic cache-hit pricing ratios" do
      bundled.each do |model_id, fields|
        next unless model_id.split("/").last.start_with?("claude-")
        next unless fields[:input] && fields[:cache_read_input]

        expected_ratio = model_id.end_with?("/claude-haiku-3") ? 0.12 : 0.1
        expect(fields[:cache_read_input]).to be_within(0.0001).of(fields[:input] * expected_ratio)
      end
    end

    it "holds the Anthropic batch-discount invariant (50% of standard input/output)" do
      bundled.each do |model_id, fields|
        next unless model_id.split("/").last.start_with?("claude-")

        if fields[:batch_input] && fields[:input]
          expect(fields[:batch_input]).to be_within(0.0001).of(fields[:input] * 0.5)
        end
        if fields[:batch_output] && fields[:output]
          expect(fields[:batch_output]).to be_within(0.0001).of(fields[:output] * 0.5)
        end
      end
    end

    it "keeps output more expensive than input for chat-style models" do
      non_chat = /embed|audio|whisper|tts|image|moderation/
      bundled.each do |model_id, fields|
        next if model_id.match?(non_chat)
        next unless fields[:input] && fields[:output]

        expect(fields[:output]).to be > fields[:input]
      end
    end
  end
end
