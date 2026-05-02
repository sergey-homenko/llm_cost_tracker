# frozen_string_literal: true

require "json"
require "spec_helper"
require "tempfile"

RSpec.describe LlmCostTracker::Pricing do
  def cost_for(provider:, model:, pricing_mode: nil, **usage)
    described_class.cost_for(
      provider: provider,
      model: model,
      pricing_mode: pricing_mode,
      token_usage: LlmCostTracker::TokenUsage.build(**usage)
    )
  end

  def explain(provider:, model:, pricing_mode: nil, **usage)
    usage = { input_tokens: 1, output_tokens: 1 }.merge(usage)
    described_class.explain(
      provider: provider,
      model: model,
      pricing_mode: pricing_mode,
      token_usage: LlmCostTracker::TokenUsage.build(**usage)
    )
  end

  describe ".normalize_mode" do
    it "treats standard provider aliases as default pricing" do
      expect(described_class.normalize_mode("standard")).to be_nil
      expect(described_class.normalize_mode("default")).to be_nil
      expect(described_class.normalize_mode("auto")).to be_nil
      expect(described_class.normalize_mode("standard_only")).to be_nil
      expect(described_class.normalize_mode(" ")).to be_nil
    end

    it "keeps non-standard pricing modes" do
      expect(described_class.normalize_mode("priority")).to eq(:priority)
      expect(described_class.normalize_mode(:priority)).to eq(:priority)
      expect(described_class.normalize_mode("data-residency")).to eq(:data_residency)
    end
  end

  describe ".stored_cost_attributes" do
    it "returns persisted cost columns" do
      attributes = {
        input_cost: 0.01,
        cache_read_input_cost: 0.02,
        cache_write_input_cost: 0.03,
        cache_write_1h_input_cost: 0.04,
        audio_input_cost: 0.06,
        output_cost: 0.05,
        audio_output_cost: 0.07,
        total_cost: 0.27,
        currency: "USD"
      }

      expect(described_class.stored_cost_attributes(attributes)).to eq(
        input_cost: 0.01,
        audio_input_cost: 0.06,
        output_cost: 0.05,
        audio_output_cost: 0.07,
        total_cost: 0.27,
        cache_read_input_cost: 0.02,
        cache_write_input_cost: 0.03,
        cache_write_1h_input_cost: 0.04
      )
    end
  end

  describe ".snapshot_for" do
    it "captures the applied token rates and source metadata" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = { "snapshot-model" => { input: 1.0, output: 2.0, batch_input: 0.5, batch_output: 1.0 } }
      end

      snapshot = described_class.snapshot_for(
        provider: "custom",
        model: "snapshot-model",
        pricing_mode: :batch,
        token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1_000, output_tokens: 500)
      )

      expect(snapshot.fetch(:schema_version)).to eq(1)
      expect(snapshot.fetch(:source)).to eq(:pricing_overrides)
      expect(snapshot.fetch(:source_version)).to eq("configuration")
      expect(snapshot.dig(:rates, :input)).to eq(amount: 0.5, quantity: 1_000_000)
      expect(snapshot.dig(:rates, :output)).to eq(amount: 1.0, quantity: 1_000_000)
    end
  end

  describe ".charge_rate" do
    it "returns nil when no service charge rate exists" do
      expect(described_class.charge_rate(provider: "gemini", component: :grounding_request, tier: nil)).to be_nil
    end

    it "returns nil when the provider is missing" do
      expect(described_class.charge_rate(provider: nil, component: :web_search_request, tier: nil)).to be_nil
    end

    it "loads provider service charge rates from the configured prices file" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write(
          {
            service_charges: {
              openai: {
                web_search_request: 10.0
              }
            },
            models: {}
          }.to_json
        )
        file.close
        LlmCostTracker.configure { |config| config.prices_file = file.path }

        rate = described_class.charge_rate(provider: "openai", component: :web_search_request, tier: nil)

        expect(rate).to include(
          amount: BigDecimal("10.0"),
          quantity: BigDecimal("1000"),
          currency: "USD",
          source: :prices_file,
          source_key: "service_charges.openai.web_search_request"
        )
        expect(rate.fetch(:source_version)).to be_a(String)
      end
    end

    it "uses tier-specific provider service charge rates" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write(
          {
            service_charges: {
              openai: {
                web_search_request: 10.0,
                priority_web_search_request: 12.0
              }
            },
            models: {}
          }.to_json
        )
        file.close
        LlmCostTracker.configure { |config| config.prices_file = file.path }

        rate = described_class.charge_rate(provider: "openai", component: :web_search_request, tier: :priority)

        expect(rate).to include(
          amount: BigDecimal("12.0"),
          source_key: "service_charges.openai.priority_web_search_request"
        )
      end
    end

    it "falls back to bundled service charge rates" do
      allow(LlmCostTracker::Pricing::ServiceCharges).to receive(:builtin_rates).and_return(
        "anthropic" => {
          web_search_request: {
            tiers: {},
            default: {
              amount: BigDecimal("5.0"),
              quantity: BigDecimal("1000"),
              currency: "USD",
              source_key: "web_search_request"
            }
          }
        }
      )

      rate = described_class.charge_rate(provider: "anthropic", component: :web_search_request, tier: nil)

      expect(rate).to include(
        amount: BigDecimal("5.0"),
        quantity: BigDecimal("1000"),
        source: :bundled,
        source_key: "service_charges.anthropic.web_search_request",
        source_version: LlmCostTracker::VERSION
      )
    end

    it "accepts provider symbols at the call boundary" do
      allow(LlmCostTracker::Pricing::ServiceCharges).to receive(:builtin_rates).and_return(
        "anthropic" => {
          web_search_request: {
            tiers: {},
            default: {
              amount: BigDecimal("5.0"),
              quantity: BigDecimal("1000"),
              currency: "USD",
              source_key: "web_search_request"
            }
          }
        }
      )

      rate = described_class.charge_rate(provider: :anthropic, component: :web_search_request, tier: nil)

      expect(rate).to include(source: :bundled)
    end

    it "rejects unknown billing components" do
      expect do
        described_class.charge_rate(provider: "openai", component: :unknown_tool, tier: nil)
      end.to raise_error(LlmCostTracker::Error, /Unknown billing component/)
    end
  end

  describe ".cost_for" do
    it "calculates cost for a known model" do
      result = cost_for(
        provider: "openai",
        model: "gpt-4o",
        input_tokens: 1_000,
        output_tokens: 500
      )

      expect(result).to be_a(Hash)
      expect(result.fetch(:input_cost)).to be > 0
      expect(result.fetch(:output_cost)).to be > 0
      expect(result.fetch(:total_cost)).to eq(result.fetch(:input_cost) + result.fetch(:output_cost))
    end

    it "calculates Groq GPT OSS cached token costs" do
      result = cost_for(
        provider: "groq",
        model: "openai/gpt-oss-20b",
        input_tokens: 1_000_000,
        cache_read_input_tokens: 1_000_000,
        output_tokens: 1_000_000
      )

      expect(result.fetch(:input_cost)).to eq(0.075)
      expect(result.fetch(:cache_read_input_cost)).to eq(0.0375)
      expect(result.fetch(:output_cost)).to eq(0.3)
      expect(result.fetch(:total_cost)).to eq(0.4125)
    end

    it "prices OpenAI Realtime audio tokens separately from text tokens" do
      result = cost_for(
        provider: "openai",
        model: "gpt-realtime-1.5",
        input_tokens: 1_000_000,
        cache_read_input_tokens: 1_000_000,
        audio_input_tokens: 1_000_000,
        output_tokens: 1_000_000,
        audio_output_tokens: 1_000_000
      )

      expect(result.fetch(:input_cost)).to eq(4.0)
      expect(result.fetch(:cache_read_input_cost)).to eq(0.4)
      expect(result.fetch(:audio_input_cost)).to eq(32.0)
      expect(result.fetch(:output_cost)).to eq(16.0)
      expect(result.fetch(:audio_output_cost)).to eq(64.0)
      expect(result.fetch(:total_cost)).to eq(116.4)
    end

    it "calculates Groq flex costs at on-demand token rates" do
      result = cost_for(
        provider: "groq",
        model: "llama-3.3-70b-versatile",
        pricing_mode: "flex",
        input_tokens: 1_000_000,
        output_tokens: 1_000_000
      )

      expect(result.fetch(:input_cost)).to eq(0.59)
      expect(result.fetch(:output_cost)).to eq(0.79)
      expect(result.fetch(:total_cost)).to eq(1.38)
    end

    it "keeps Groq provisioned performance pricing unknown" do
      result = cost_for(
        provider: "groq",
        model: "openai/gpt-oss-120b",
        pricing_mode: "performance",
        input_tokens: 1_000,
        output_tokens: 1_000
      )

      expect(result).to be_nil
    end

    it "returns nil for unknown models" do
      result = cost_for(
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

      result = cost_for(
        provider: "custom",
        model: "demo-base-2026-01-01",
        input_tokens: 1_000_000,
        output_tokens: 0
      )

      expect(result.fetch(:input_cost)).to eq(1.0)
    end

    it "matches provider-prefixed model names from gateways" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = { "demo-mini" => { input: 0.1, output: 0.4 } }
      end

      result = cost_for(
        provider: "demogateway",
        model: "demo/demo-mini",
        input_tokens: 1_000_000,
        output_tokens: 0
      )

      expect(result.fetch(:input_cost)).to eq(0.1)
    end

    it "matches unique provider-qualified prices for gateway model names" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = { "upstream/demo-mini" => { input: 0.1, output: 0.4 } }
      end

      result = cost_for(
        provider: "gateway",
        model: "demo-mini",
        input_tokens: 1_000_000,
        output_tokens: 0
      )

      expect(result.fetch(:input_cost)).to eq(0.1)
    end

    it "does not match ambiguous provider-qualified prices by model name alone" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "first/demo-mini" => { input: 0.1, output: 0.4 },
          "second/demo-mini" => { input: 0.2, output: 0.8 }
        }
      end

      result = cost_for(
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

      result = cost_for(
        provider: "custom",
        model: "demo-family-mini-2026-01-01",
        input_tokens: 1_000_000,
        output_tokens: 0
      )

      expect(result.fetch(:input_cost)).to eq(0.5)
    end

    it "does not fuzzy-match unknown model families to older prices" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = { "demo-1.0" => { input: 1.0, output: 2.0 } }
      end

      expect(
        cost_for(provider: "custom", model: "demo-2.0", input_tokens: 1_000_000, output_tokens: 0)
      ).to be_nil
    end

    it "does not fuzzy-match unknown model variants to base prices" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "base-model" => { input: 1.0, output: 2.0 }
        }
      end

      result = cost_for(
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

      result = cost_for(
        provider: "custom",
        model: "demo-cached",
        input_tokens: 600_000,
        cache_read_input_tokens: 400_000,
        output_tokens: 0
      )

      expect(result.fetch(:input_cost)).to eq(0.15)
      expect(result.fetch(:cache_read_input_cost)).to eq(0.01)
      expect(result.fetch(:total_cost)).to eq(0.16)
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

      result = cost_for(
        provider: "custom",
        model: "demo-cache-rw",
        input_tokens: 100_000,
        cache_read_input_tokens: 200_000,
        cache_write_input_tokens: 300_000,
        output_tokens: 10_000
      )

      expect(result.fetch(:input_cost)).to eq(0.3)
      expect(result.fetch(:cache_read_input_cost)).to eq(0.06)
      expect(result.fetch(:cache_write_input_cost)).to eq(1.125)
      expect(result.fetch(:cache_write_1h_input_cost)).to eq(0.0)
      expect(result.fetch(:output_cost)).to eq(0.15)
      expect(result.fetch(:total_cost)).to be_within(0.0001).of(
        result.fetch(:input_cost) + result.fetch(:cache_read_input_cost) +
          result.fetch(:cache_write_input_cost) + result.fetch(:cache_write_1h_input_cost) + result.fetch(:output_cost)
      )
    end

    it "prices 1-hour cache writes with their own rate when usage exposes the split" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "anthropic/demo-cache-ttl" => {
            input: 3.0,
            output: 15.0,
            cache_write_input: 3.75,
            cache_write_1h_input: 6.0
          }
        }
      end

      result = cost_for(
        provider: "anthropic",
        model: "demo-cache-ttl",
        input_tokens: 0,
        cache_write_input_tokens: 300_000,
        cache_write_1h_input_tokens: 100_000,
        output_tokens: 0
      )

      expect(result.fetch(:cache_write_input_cost)).to eq(1.125)
      expect(result.fetch(:cache_write_1h_input_cost)).to eq(0.6)
      expect(result.fetch(:total_cost)).to eq(1.725)
    end

    it "derives batch cache rates from the batch input discount when the provider stacks modifiers" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "anthropic/demo-cache-batch" => {
            input: 3.0,
            output: 15.0,
            cache_read_input: 0.3,
            cache_write_input: 3.75,
            cache_write_1h_input: 6.0,
            batch_input: 1.5,
            batch_output: 7.5
          }
        }
      end

      result = cost_for(
        provider: "anthropic",
        model: "demo-cache-batch",
        input_tokens: 100_000,
        cache_read_input_tokens: 100_000,
        cache_write_input_tokens: 100_000,
        cache_write_1h_input_tokens: 100_000,
        output_tokens: 100_000,
        pricing_mode: :batch
      )

      expect(result.fetch(:input_cost)).to eq(0.15)
      expect(result.fetch(:cache_read_input_cost)).to eq(0.015)
      expect(result.fetch(:cache_write_input_cost)).to eq(0.1875)
      expect(result.fetch(:cache_write_1h_input_cost)).to eq(0.3)
      expect(result.fetch(:output_cost)).to eq(0.75)
      expect(result.fetch(:total_cost)).to eq(1.4025)
    end

    it "derives cache rates for any mode with a documented input multiplier" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "anthropic/demo-data-residency" => {
            input: 3.0,
            output: 15.0,
            cache_read_input: 0.3,
            cache_write_input: 3.75,
            data_residency_input: 3.3,
            data_residency_output: 16.5
          }
        }
      end

      result = cost_for(
        provider: "anthropic",
        model: "demo-data-residency",
        input_tokens: 100_000,
        cache_read_input_tokens: 100_000,
        cache_write_input_tokens: 100_000,
        output_tokens: 100_000,
        pricing_mode: :data_residency
      )

      expect(result.fetch(:input_cost)).to eq(0.33)
      expect(result.fetch(:cache_read_input_cost)).to eq(0.033)
      expect(result.fetch(:cache_write_input_cost)).to eq(0.4125)
      expect(result.fetch(:output_cost)).to eq(1.65)
      expect(result.fetch(:total_cost)).to eq(2.4255)
    end

    it "treats 1-hour cache writes as unknown pricing when the 1-hour rate is missing" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "anthropic/demo-cache-ttl" => {
            input: 3.0,
            output: 15.0,
            cache_write_input: 3.75
          }
        }
      end

      result = cost_for(
        provider: "anthropic",
        model: "demo-cache-ttl",
        input_tokens: 0,
        cache_write_input_tokens: 100_000,
        cache_write_1h_input_tokens: 100_000,
        output_tokens: 0
      )

      expect(result).to be_nil
    end

    it "treats cache writes as unknown pricing when no cache-write rate exists" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "gemini/demo-cache" => {
            input: 1.0,
            output: 2.0,
            cache_read_input: 0.1
          }
        }
      end

      result = cost_for(
        provider: "gemini",
        model: "demo-cache",
        input_tokens: 0,
        cache_write_input_tokens: 100_000,
        output_tokens: 0
      )

      expect(result).to be_nil
    end

    it "uses pricing overrides when configured" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "my-custom-model" => { input: 1.0, output: 2.0 }
        }
      end

      result = cost_for(
        provider: "custom",
        model: "my-custom-model",
        input_tokens: 1_000_000,
        output_tokens: 1_000_000
      )

      expect(result.fetch(:input_cost)).to eq(1.0)
      expect(result.fetch(:output_cost)).to eq(2.0)
    end

    it "returns nil when a matched price is missing a required component" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "input-only-model" => { input: 1.0 }
        }
      end

      result = cost_for(
        provider: "custom",
        model: "input-only-model",
        input_tokens: 1_000_000,
        output_tokens: 1_000_000
      )

      expect(result).to be_nil
    end

    it "prices zero-token missing components as zero" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "input-only-model" => { input: 1.0 }
        }
      end

      result = cost_for(
        provider: "custom",
        model: "input-only-model",
        input_tokens: 1_000_000,
        output_tokens: 0
      )

      expect(result.fetch(:input_cost)).to eq(1.0)
      expect(result.fetch(:output_cost)).to eq(0.0)
      expect(result.fetch(:total_cost)).to eq(1.0)
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

      result = cost_for(
        provider: "custom",
        model: "batchable-model",
        input_tokens: 1_000_000,
        output_tokens: 1_000_000,
        pricing_mode: :batch
      )

      expect(result.fetch(:input_cost)).to eq(0.5)
      expect(result.fetch(:output_cost)).to eq(1.0)
      expect(result.fetch(:total_cost)).to eq(1.5)
    end

    it "prices OpenAI Priority mode from bundled rates" do
      result = cost_for(
        provider: "openai",
        model: "gpt-5.5",
        input_tokens: 100_000,
        output_tokens: 100_000,
        pricing_mode: :priority
      )

      expect(result.fetch(:input_cost)).to eq(1.25)
      expect(result.fetch(:output_cost)).to eq(7.5)
      expect(result.fetch(:total_cost)).to eq(8.75)
    end

    it "prices OpenAI regional Priority mode from bundled rates" do
      result = cost_for(
        provider: "openai",
        model: "gpt-5.5",
        input_tokens: 100_000,
        output_tokens: 100_000,
        pricing_mode: :priority_data_residency
      )

      expect(result.fetch(:input_cost)).to eq(1.375)
      expect(result.fetch(:output_cost)).to eq(8.25)
      expect(result.fetch(:total_cost)).to eq(9.625)
    end

    it "prices Anthropic fast data residency mode from bundled rates" do
      result = cost_for(
        provider: "anthropic",
        model: "claude-opus-4-6",
        input_tokens: 1_000_000,
        output_tokens: 1_000_000,
        pricing_mode: :fast_data_residency
      )

      expect(result.fetch(:input_cost)).to eq(33.0)
      expect(result.fetch(:output_cost)).to eq(165.0)
      expect(result.fetch(:total_cost)).to eq(198.0)
    end

    it "returns nil when a positive-token pricing mode is missing a required rate" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "mixed-mode-model" => {
            input: 1.0,
            output: 2.0,
            batch_input: 0.5
          }
        }
      end

      result = cost_for(
        provider: "custom",
        model: "mixed-mode-model",
        input_tokens: 1_000_000,
        output_tokens: 1_000_000,
        pricing_mode: :batch
      )

      expect(result).to be_nil
    end

    it "does not price unsupported pricing modes with standard rates" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "fast-mode-model" => {
            input: 1.0,
            output: 2.0
          }
        }
      end

      result = cost_for(
        provider: "custom",
        model: "fast-mode-model",
        input_tokens: 1_000_000,
        output_tokens: 0,
        pricing_mode: :fast
      )

      expect(result).to be_nil
    end

    it "uses above-context rates when input-side tokens cross the pricing threshold" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "tiered-model" => {
            input: 1.0,
            output: 2.0,
            cache_read_input: 0.1,
            _context_price_threshold_tokens: 200_000,
            above_context_input: 3.0,
            above_context_output: 4.0,
            above_context_cache_read_input: 0.3
          }
        }
      end

      result = cost_for(
        provider: "custom",
        model: "tiered-model",
        input_tokens: 150_000,
        cache_read_input_tokens: 60_000,
        output_tokens: 100_000
      )

      expect(result.fetch(:input_cost)).to eq(0.45)
      expect(result.fetch(:cache_read_input_cost)).to eq(0.018)
      expect(result.fetch(:output_cost)).to eq(0.4)
      expect(result.fetch(:total_cost)).to eq(0.868)
    end

    it "uses above-context mode rates for batch pricing" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "tiered-batch-model" => {
            input: 2.0,
            output: 8.0,
            cache_read_input: 0.2,
            batch_input: 1.0,
            batch_output: 4.0,
            batch_cache_read_input: 0.1,
            _context_price_threshold_tokens: 200_000,
            above_context_input: 4.0,
            above_context_output: 12.0,
            above_context_cache_read_input: 0.4,
            above_context_batch_input: 2.0,
            above_context_batch_output: 6.0,
            above_context_batch_cache_read_input: 0.2
          }
        }
      end

      result = cost_for(
        provider: "custom",
        model: "tiered-batch-model",
        input_tokens: 150_000,
        cache_read_input_tokens: 60_000,
        output_tokens: 100_000,
        pricing_mode: :batch
      )

      expect(result.fetch(:input_cost)).to eq(0.3)
      expect(result.fetch(:cache_read_input_cost)).to eq(0.012)
      expect(result.fetch(:output_cost)).to eq(0.6)
      expect(result.fetch(:total_cost)).to eq(0.912)
    end

    it "does not use short-context rates when a crossed context tier is incomplete" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "incomplete-tier-model" => {
            input: 1.0,
            output: 2.0,
            _context_price_threshold_tokens: 200_000,
            above_context_input: 3.0
          }
        }
      end

      result = cost_for(
        provider: "custom",
        model: "incomplete-tier-model",
        input_tokens: 250_000,
        output_tokens: 100_000
      )

      expect(result).to be_nil
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

        result = cost_for(
          provider: "openai",
          model: "gpt-4o",
          input_tokens: 1_000_000,
          output_tokens: 0
        )

        expect(result.fetch(:input_cost)).to eq(9.0)
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

        result = cost_for(
          provider: "custom",
          model: "my-custom-model",
          input_tokens: 1_000_000,
          output_tokens: 1_000_000
        )

        expect(result.fetch(:input_cost)).to eq(1.0)
        expect(result.fetch(:output_cost)).to eq(2.0)
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

        result = cost_for(
          provider: "custom",
          model: "yaml-model",
          input_tokens: 1_000_000,
          output_tokens: 1_000_000
        )

        expect(result.fetch(:input_cost)).to eq(3.0)
        expect(result.fetch(:output_cost)).to eq(4.0)
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
          cost_for(provider: "openai", model: "gpt-4o", input_tokens: 1, output_tokens: 1)
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

      result = cost_for(
        provider: "deepseek",
        model: "deepseek-chat",
        input_tokens: 1_000_000,
        output_tokens: 1_000_000
      )

      expect(result.fetch(:input_cost)).to eq(0.2)
      expect(result.fetch(:output_cost)).to eq(0.9)
    end
  end

  describe ".lookup" do
    it "returns consistent sorted keys under concurrent lookup" do
      if LlmCostTracker::Pricing::Lookup.instance_variable_defined?(:@sorted_price_keys_cache)
        LlmCostTracker::Pricing::Lookup.remove_instance_variable(:@sorted_price_keys_cache)
      end

      table = {
        "gpt-4" => { input: 30.0, output: 60.0 },
        "gpt-4o" => { input: 2.5, output: 10.0 }
      }

      results = 10.times.map do
        Thread.new { LlmCostTracker::Pricing::Lookup.send(:sorted_price_keys, table) }
      end.map(&:value)

      expect(results).to all(eq(%w[gpt-4o gpt-4]))
    end

    it "invalidates cached matches when configuration resets" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "custom/cached-model" => { input: 1.0, output: 2.0 }
        }
      end

      expect(described_class.lookup(provider: "custom", model: "cached-model")).to include(input: 1.0)

      LlmCostTracker.reset_configuration!
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "custom/cached-model" => { input: 3.0, output: 4.0 }
        }
      end

      expect(described_class.lookup(provider: "custom", model: "cached-model")).to include(input: 3.0)
    end

    it "caches configured price files between lookups" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write(JSON.generate("models" => {
                                   "cached-file-model" => { "input" => 9.0, "output" => 10.0 }
                                 }))
        file.close

        LlmCostTracker.configure { |c| c.prices_file = file.path }
        allow(LlmCostTracker::Pricing::Registry).to receive(:file_prices).and_call_original

        2.times { described_class.lookup(provider: "custom", model: "cached-file-model") }

        expect(LlmCostTracker::Pricing::Registry).to have_received(:file_prices).once
      end
    end
  end

  describe ".explain" do
    it "explains the matched pricing source and effective rates" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "custom/explained-model" => { input: 1.0, output: 2.0, batch_input: 0.5, batch_output: 1.0 }
        }
      end

      result = explain(
        provider: "custom",
        model: "explained-model",
        pricing_mode: :batch
      )

      expect(result).to have_attributes(
        source: :pricing_overrides,
        matched_key: "custom/explained-model",
        matched_by: :provider_model,
        pricing_mode: :batch,
        missing_price_keys: []
      )
      expect(result.effective_prices).to include(input: 0.5, output: 1.0)
      expect(result.message).to include("Matched custom/explained-model")
    end

    it "explains missing required price keys" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "input-only-model" => { input: 1.0 }
        }
      end

      result = explain(
        provider: "custom",
        model: "input-only-model",
        input_tokens: 1,
        output_tokens: 1
      )

      expect(result.matched?).to be true
      expect(result.complete?).to be false
      expect(result.missing_price_keys).to eq([:output])
      expect(result.message).to include("missing output")
    end

    it "explains unknown models" do
      result = explain(provider: "custom", model: "missing-model")

      expect(result.matched?).to be false
      expect(result.complete?).to be false
      expect(result.message).to include("No price entry matched custom/missing-model")
    end
  end

  describe "bundled price snapshot" do
    let(:bundled) { LlmCostTracker::Pricing::Registry.builtin_prices }

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
          next unless LlmCostTracker::Pricing::Registry::PRICE_KEYS.include?(field_name) ||
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

    it "holds the Anthropic 1-hour cache-write pricing ratios" do
      bundled.each do |model_id, fields|
        next unless model_id.split("/").last.start_with?("claude-")

        expect(fields[:cache_write_1h_input]).to be_within(0.0001).of(fields[:input] * 2.0)
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

    it "keeps Gemini 2.5 Pro long-context prices above the 200k prompt threshold" do
      fields = bundled.fetch("gemini/gemini-2.5-pro")

      expect(fields[:_context_price_threshold_tokens]).to eq(200_000)
      expect(fields[:above_context_input]).to eq(2.5)
      expect(fields[:above_context_output]).to eq(15.0)
      expect(fields[:above_context_cache_read_input]).to eq(0.25)
      expect(fields[:above_context_batch_input]).to eq(1.25)
      expect(fields[:above_context_batch_output]).to eq(7.5)
      expect(fields[:above_context_batch_cache_read_input]).to eq(0.25)
    end

    it "keeps OpenAI 1.05M-context models on their long-context rates" do
      {
        "openai/gpt-5.4" => [5.0, 22.5],
        "openai/gpt-5.4-pro" => [60.0, 270.0],
        "openai/gpt-5.5" => [10.0, 45.0],
        "openai/gpt-5.5-pro" => [60.0, 270.0]
      }.each do |model_id, (input, output)|
        fields = bundled.fetch(model_id)

        expect(fields[:_context_price_threshold_tokens]).to eq(272_000)
        expect(fields[:above_context_input]).to eq(input)
        expect(fields[:above_context_output]).to eq(output)
      end
    end

    it "keeps Groq prompt cache reads at 50% of input pricing" do
      bundled.each do |model_id, fields|
        next unless model_id.start_with?("groq/")
        next unless fields[:cache_read_input]

        expect(fields[:cache_read_input]).to be_within(0.0001).of(fields[:input] * 0.5)
      end
    end

    it "keeps Groq flex token pricing equal to on-demand pricing" do
      bundled.each do |model_id, fields|
        next unless model_id.start_with?("groq/")
        next unless fields[:flex_input]

        expect(fields[:flex_input]).to eq(fields[:on_demand_input])
        expect(fields[:flex_output]).to eq(fields[:on_demand_output])
        if fields[:flex_cache_read_input]
          expect(fields[:flex_cache_read_input]).to eq(fields[:on_demand_cache_read_input])
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
