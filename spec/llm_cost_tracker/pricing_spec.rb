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
      tokens: LlmCostTracker::Usage::TokenUsage.build(**usage)
    )
  end

  context "model fallback resolution" do
    it "returns nil for an empty model lookup before touching the price tables" do
      expect(LlmCostTracker::Pricing::Matcher.lookup(provider: "openai", model: "")).to be_nil
      expect(LlmCostTracker::Pricing::Matcher.lookup(provider: "openai", model: nil)).to be_nil
    end

    it "resolves azure_openai/<model> through the unique-providerless fallback to OpenAI direct entries" do
      match = LlmCostTracker::Pricing::Matcher.lookup(provider: "azure_openai", model: "gpt-4o-mini")

      expect(match).not_to be_nil
      expect(match.key).to eq("openai/gpt-4o-mini")
      expect(match.matched_by).to eq(:unique_providerless_model)
    end

    it "resolves dated azure_openai snapshots through the unique-providerless dated-snapshot fallback" do
      match = LlmCostTracker::Pricing::Matcher.lookup(provider: "azure_openai", model: "gpt-4o-2024-08-06")

      expect(match).not_to be_nil
      expect(match.key).to eq("openai/gpt-4o")
      expect(match.matched_by).to eq(:unique_providerless_dated_snapshot)
    end

    it "resolves Gemini preview-dated snapshots (preview-MM-DD) to the stable model entry" do
      match = LlmCostTracker::Pricing::Matcher.lookup(provider: "gemini", model: "gemini-2.5-flash-preview-04-17")

      expect(match).not_to be_nil
      expect(match.key).to eq("gemini/gemini-2.5-flash")
      expect(match.matched_by).to eq(:dated_snapshot)
    end

    it "resolves Gemini preview-dated snapshots with a four-digit year (preview-MM-YYYY)" do
      match = LlmCostTracker::Pricing::Matcher.lookup(provider: "gemini", model: "gemini-2.5-flash-preview-09-2025")

      expect(match).not_to be_nil
      expect(match.matched_by).to eq(:dated_snapshot)
    end
  end

  context "match caching" do
    it "returns the same memoized match for a repeated lookup" do
      first = LlmCostTracker::Pricing::Matcher.lookup(provider: "openai", model: "gpt-4o")
      second = LlmCostTracker::Pricing::Matcher.lookup(provider: "openai", model: "gpt-4o")

      expect(first).not_to be_nil
      expect(second).to equal(first)
    end

    it "memoizes a miss so a repeated unknown lookup stays nil" do
      expect(LlmCostTracker::Pricing::Matcher.lookup(provider: "openai", model: "no-such-model-xyz")).to be_nil
      expect(LlmCostTracker::Pricing::Matcher.lookup(provider: "openai", model: "no-such-model-xyz")).to be_nil
    end

    it "serves fresh prices after a registry reset instead of a stale cached match" do
      LlmCostTracker.configure { |c| c.pricing_overrides = { "ledger-demo" => { "input" => 1.0, "output" => 2.0 } } }
      cached = LlmCostTracker::Pricing::Matcher.lookup(provider: nil, model: "ledger-demo")
      expect(LlmCostTracker::Pricing::Matcher.lookup(provider: nil, model: "ledger-demo")).to equal(cached)

      LlmCostTracker.instance_variable_set(:@configuration, LlmCostTracker::Configuration.new)
      LlmCostTracker.configure { |c| c.pricing_overrides = { "ledger-demo" => { "input" => 7.0, "output" => 2.0 } } }

      refreshed = LlmCostTracker::Pricing::Matcher.lookup(provider: nil, model: "ledger-demo")
      expect(refreshed).not_to equal(cached)
      expect(refreshed.prices.fetch("input").to_f).to eq(7.0)
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

      expect(result).to be_a(LlmCostTracker::Charges::Cost)
      expect(result.components.fetch(:input_cost)).to be > 0
      expect(result.components.fetch(:output_cost)).to be > 0
      expect(result.total).to eq(result.components.fetch(:input_cost) + result.components.fetch(:output_cost))
    end

    it "calculates Groq GPT OSS cached token costs" do
      result = cost_for(
        provider: "groq",
        model: "openai/gpt-oss-20b",
        input_tokens: 1_000_000,
        cache_read_input_tokens: 1_000_000,
        output_tokens: 1_000_000
      )

      expect(result.components.fetch(:input_cost)).to eq(0.075)
      expect(result.components.fetch(:cache_read_input_cost)).to eq(0.0375)
      expect(result.components.fetch(:output_cost)).to eq(0.3)
      expect(result.total).to eq(0.4125)
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

      expect(result.components.fetch(:input_cost)).to eq(4.0)
      expect(result.components.fetch(:cache_read_input_cost)).to eq(0.4)
      expect(result.components.fetch(:audio_input_cost)).to eq(32.0)
      expect(result.components.fetch(:output_cost)).to eq(16.0)
      expect(result.components.fetch(:audio_output_cost)).to eq(64.0)
      expect(result.total).to eq(116.4)
    end

    it "prices OpenAI audio model tokens separately from text tokens" do
      result = cost_for(
        provider: "openai",
        model: "gpt-audio-1.5",
        input_tokens: 1_000_000,
        audio_input_tokens: 1_000_000,
        output_tokens: 1_000_000,
        audio_output_tokens: 1_000_000
      )

      expect(result.components.fetch(:input_cost)).to eq(2.5)
      expect(result.components.fetch(:audio_input_cost)).to eq(32.0)
      expect(result.components.fetch(:output_cost)).to eq(10.0)
      expect(result.components.fetch(:audio_output_cost)).to eq(64.0)
      expect(result.total).to eq(108.5)
    end

    it "prices Gemini audio input tokens separately from text tokens" do
      result = cost_for(
        provider: "gemini",
        model: "gemini-2.5-flash",
        input_tokens: 1_000_000,
        audio_input_tokens: 1_000_000,
        output_tokens: 1_000_000
      )

      expect(result.components.fetch(:input_cost)).to eq(0.3)
      expect(result.components.fetch(:audio_input_cost)).to eq(1.0)
      expect(result.components.fetch(:output_cost)).to eq(2.5)
      expect(result.total).to eq(3.8)
    end

    it "calculates Groq flex costs at on-demand token rates" do
      result = cost_for(
        provider: "groq",
        model: "openai/gpt-oss-120b",
        pricing_mode: "flex",
        input_tokens: 1_000_000,
        output_tokens: 1_000_000
      )

      expect(result.components.fetch(:input_cost)).to eq(0.15)
      expect(result.components.fetch(:output_cost)).to eq(0.6)
      expect(result.total).to eq(0.75)
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
        c.pricing_overrides = { "demo-base" => { "input" => 1.0, "output" => 2.0 } }
      end

      result = cost_for(
        provider: "custom",
        model: "demo-base-2026-01-01",
        input_tokens: 1_000_000,
        output_tokens: 0
      )

      expect(result.components.fetch(:input_cost)).to eq(1.0)
    end

    it "matches provider-prefixed model names from gateways" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = { "demo-mini" => { "input" => 0.1, "output" => 0.4 } }
      end

      result = cost_for(
        provider: "demogateway",
        model: "demo/demo-mini",
        input_tokens: 1_000_000,
        output_tokens: 0
      )

      expect(result.components.fetch(:input_cost)).to eq(0.1)
    end

    it "matches unique provider-qualified prices for gateway model names" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = { "upstream/demo-mini" => { "input" => 0.1, "output" => 0.4 } }
      end

      result = cost_for(
        provider: "gateway",
        model: "demo-mini",
        input_tokens: 1_000_000,
        output_tokens: 0
      )

      expect(result.components.fetch(:input_cost)).to eq(0.1)
    end

    it "does not match ambiguous provider-qualified prices by model name alone" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "first/demo-mini" => { "input" => 0.1, "output" => 0.4 },
          "second/demo-mini" => { "input" => 0.2, "output" => 0.8 }
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
          "demo-family" => { "input" => 5.0, "output" => 10.0 },
          "demo-family-mini" => { "input" => 0.5, "output" => 1.0 }
        }
      end

      result = cost_for(
        provider: "custom",
        model: "demo-family-mini-2026-01-01",
        input_tokens: 1_000_000,
        output_tokens: 0
      )

      expect(result.components.fetch(:input_cost)).to eq(0.5)
    end

    it "does not fuzzy-match unknown model families to older prices" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = { "demo-1.0" => { "input" => 1.0, "output" => 2.0 } }
      end

      expect(
        cost_for(provider: "custom", model: "demo-2.0", input_tokens: 1_000_000, output_tokens: 0)
      ).to be_nil
    end

    it "does not fuzzy-match unknown model variants to base prices" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "base-model" => { "input" => 1.0, "output" => 2.0 }
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
          "demo-cached" => { "input" => 0.25, "output" => 2.0, "cache_read_input" => 0.025 }
        }
      end

      result = cost_for(
        provider: "custom",
        model: "demo-cached",
        input_tokens: 600_000,
        cache_read_input_tokens: 400_000,
        output_tokens: 0
      )

      expect(result.components.fetch(:input_cost)).to eq(0.15)
      expect(result.components.fetch(:cache_read_input_cost)).to eq(0.01)
      expect(result.total).to eq(0.16)
    end

    it "prices cache read and write tokens separately and sums into total" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "demo-cache-rw" => {
            "input" => 3.0,
            "output" => 15.0,
            "cache_read_input" => 0.3,
            "cache_write_input" => 3.75
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

      expect(result.components.fetch(:input_cost)).to eq(0.3)
      expect(result.components.fetch(:cache_read_input_cost)).to eq(0.06)
      expect(result.components.fetch(:cache_write_input_cost)).to eq(1.125)
      expect(result.components.fetch(:cache_write_extended_input_cost)).to eq(0.0)
      expect(result.components.fetch(:output_cost)).to eq(0.15)
      expect(result.total).to be_within(0.0001).of(
        result.components.fetch(:input_cost) + result.components.fetch(:cache_read_input_cost) +
          result.components.fetch(:cache_write_input_cost) + result.components.fetch(:cache_write_extended_input_cost) + result.components.fetch(:output_cost)
      )
    end

    it "prices extended cache writes with their own rate when usage exposes the split" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "anthropic/demo-cache-ttl" => {
            "input" => 3.0,
            "output" => 15.0,
            "cache_write_input" => 3.75,
            "cache_write_extended_input" => 6.0
          }
        }
      end

      result = cost_for(
        provider: "anthropic",
        model: "demo-cache-ttl",
        input_tokens: 0,
        cache_write_input_tokens: 300_000,
        cache_write_extended_input_tokens: 100_000,
        output_tokens: 0
      )

      expect(result.components.fetch(:cache_write_input_cost)).to eq(1.125)
      expect(result.components.fetch(:cache_write_extended_input_cost)).to eq(0.6)
      expect(result.total).to eq(1.725)
    end

    it "derives batch cache rates from the batch input discount when the provider stacks modifiers" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "anthropic/demo-cache-batch" => {
            "input" => 3.0,
            "output" => 15.0,
            "cache_read_input" => 0.3,
            "cache_write_input" => 3.75,
            "cache_write_extended_input" => 6.0,
            "batch_input" => 1.5,
            "batch_output" => 7.5
          }
        }
      end

      result = cost_for(
        provider: "anthropic",
        model: "demo-cache-batch",
        input_tokens: 100_000,
        cache_read_input_tokens: 100_000,
        cache_write_input_tokens: 100_000,
        cache_write_extended_input_tokens: 100_000,
        output_tokens: 100_000,
        pricing_mode: "batch"
      )

      expect(result.components.fetch(:input_cost)).to eq(0.15)
      expect(result.components.fetch(:cache_read_input_cost)).to eq(0.015)
      expect(result.components.fetch(:cache_write_input_cost)).to eq(0.1875)
      expect(result.components.fetch(:cache_write_extended_input_cost)).to eq(0.3)
      expect(result.components.fetch(:output_cost)).to eq(0.75)
      expect(result.total).to eq(1.4025)
    end

    it "derives cache rates for any mode with a documented input multiplier" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "anthropic/demo-data-residency" => {
            "input" => 3.0,
            "output" => 15.0,
            "cache_read_input" => 0.3,
            "cache_write_input" => 3.75,
            "data_residency_input" => 3.3,
            "data_residency_output" => 16.5
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
        pricing_mode: "data_residency"
      )

      expect(result.components.fetch(:input_cost)).to eq(0.33)
      expect(result.components.fetch(:cache_read_input_cost)).to eq(0.033)
      expect(result.components.fetch(:cache_write_input_cost)).to eq(0.4125)
      expect(result.components.fetch(:output_cost)).to eq(1.65)
      expect(result.total).to eq(2.4255)
    end

    it "prices priced cache components and omits the missing extended cache rate" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "anthropic/demo-cache-ttl" => {
            "input" => 3.0,
            "output" => 15.0,
            "cache_write_input" => 3.75
          }
        }
      end

      result = cost_for(
        provider: "anthropic",
        model: "demo-cache-ttl",
        input_tokens: 0,
        cache_write_input_tokens: 100_000,
        cache_write_extended_input_tokens: 100_000,
        output_tokens: 0
      )

      expect(result).to have_attributes(total: 0.375, components: include(cache_write_input_cost: 0.375))
      expect(result.components).not_to have_key(:cache_write_extended_input_cost)
    end

    it "treats cache writes as unknown pricing when no cache-write rate exists" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "gemini/demo-cache" => {
            "input" => 1.0,
            "output" => 2.0,
            "cache_read_input" => 0.1
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
          "my-custom-model" => { "input" => 1.0, "output" => 2.0 }
        }
      end

      result = cost_for(
        provider: "custom",
        model: "my-custom-model",
        input_tokens: 1_000_000,
        output_tokens: 1_000_000
      )

      expect(result.components.fetch(:input_cost)).to eq(1.0)
      expect(result.components.fetch(:output_cost)).to eq(2.0)
    end

    it "prices billable components when a matched price is missing a required component" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "input-only-model" => { "input" => 1.0 }
        }
      end

      result = cost_for(
        provider: "custom",
        model: "input-only-model",
        input_tokens: 1_000_000,
        output_tokens: 1_000_000
      )

      expect(result).to have_attributes(total: 1.0, components: include(input_cost: 1.0))
      expect(result.components).not_to have_key(:output_cost)
    end

    it "prices zero-token missing components as zero" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "input-only-model" => { "input" => 1.0 }
        }
      end

      result = cost_for(
        provider: "custom",
        model: "input-only-model",
        input_tokens: 1_000_000,
        output_tokens: 0
      )

      expect(result.components.fetch(:input_cost)).to eq(1.0)
      expect(result.components.fetch(:output_cost)).to eq(0.0)
      expect(result.total).to eq(1.0)
    end

    it "uses mode-specific price keys when pricing_mode is provided" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "batchable-model" => {
            "input" => 1.0,
            "output" => 2.0,
            "batch_input" => 0.5,
            "batch_output" => 1.0
          }
        }
      end

      result = cost_for(
        provider: "custom",
        model: "batchable-model",
        input_tokens: 1_000_000,
        output_tokens: 1_000_000,
        pricing_mode: "batch"
      )

      expect(result.components.fetch(:input_cost)).to eq(0.5)
      expect(result.components.fetch(:output_cost)).to eq(1.0)
      expect(result.total).to eq(1.5)
    end

    it "prices OpenAI Priority mode from bundled rates" do
      result = cost_for(
        provider: "openai",
        model: "gpt-5.5",
        input_tokens: 100_000,
        output_tokens: 100_000,
        pricing_mode: "priority"
      )

      expect(result.components.fetch(:input_cost)).to eq(1.25)
      expect(result.components.fetch(:output_cost)).to eq(7.5)
      expect(result.total).to eq(8.75)
    end

    it "prices OpenAI regional Priority mode from bundled rates" do
      result = cost_for(
        provider: "openai",
        model: "gpt-5.5",
        input_tokens: 100_000,
        output_tokens: 100_000,
        pricing_mode: "priority_data_residency"
      )

      expect(result.components.fetch(:input_cost)).to eq(1.375)
      expect(result.components.fetch(:output_cost)).to eq(8.25)
      expect(result.total).to eq(9.625)
    end

    it "prices Anthropic fast data residency mode from bundled rates" do
      result = cost_for(
        provider: "anthropic",
        model: "claude-opus-4-8",
        input_tokens: 1_000_000,
        output_tokens: 1_000_000,
        pricing_mode: "fast_data_residency"
      )

      expect(result.components.fetch(:input_cost)).to eq(11.0)
      expect(result.components.fetch(:output_cost)).to eq(55.0)
      expect(result.total).to eq(66.0)
    end

    it "prices billable components when a positive-token pricing mode is missing a required rate" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "mixed-mode-model" => {
            "input" => 1.0,
            "output" => 2.0,
            "batch_input" => 0.5
          }
        }
      end

      result = cost_for(
        provider: "custom",
        model: "mixed-mode-model",
        input_tokens: 1_000_000,
        output_tokens: 1_000_000,
        pricing_mode: "batch"
      )

      expect(result).to have_attributes(total: 0.5, components: include(input_cost: 0.5))
      expect(result.components).not_to have_key(:output_cost)
    end

    it "does not price unsupported pricing modes with standard rates" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "fast-mode-model" => {
            "input" => 1.0,
            "output" => 2.0
          }
        }
      end

      result = cost_for(
        provider: "custom",
        model: "fast-mode-model",
        input_tokens: 1_000_000,
        output_tokens: 0,
        pricing_mode: "fast"
      )

      expect(result).to be_nil
    end

    it "counts image_input_tokens toward the context threshold so image-heavy inputs trigger above-context rates" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "tiered-image-model" => {
            "input" => 1.0,
            "output" => 2.0,
            "image_input" => 0.5,
            "_context_price_threshold_tokens" => 100_000,
            "above_context_input" => 3.0,
            "above_context_output" => 4.0,
            "above_context_image_input" => 1.5
          }
        }
      end

      result = cost_for(
        provider: "custom",
        model: "tiered-image-model",
        input_tokens: 20_000,
        image_input_tokens: 120_000,
        output_tokens: 1_000
      )

      expect(result.components.fetch(:input_cost)).to eq(0.06)
      expect(result.components.fetch(:image_input_cost)).to eq(0.18)
      expect(result.components.fetch(:output_cost)).to eq(0.004)
    end

    it "uses above-context rates when input-side tokens cross the pricing threshold" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "tiered-model" => {
            "input" => 1.0,
            "output" => 2.0,
            "cache_read_input" => 0.1,
            "_context_price_threshold_tokens" => 200_000,
            "above_context_input" => 3.0,
            "above_context_output" => 4.0,
            "above_context_cache_read_input" => 0.3
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

      expect(result.components.fetch(:input_cost)).to eq(0.45)
      expect(result.components.fetch(:cache_read_input_cost)).to eq(0.018)
      expect(result.components.fetch(:output_cost)).to eq(0.4)
      expect(result.total).to eq(0.868)
    end

    it "uses above-context mode rates for batch pricing" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "tiered-batch-model" => {
            "input" => 2.0,
            "output" => 8.0,
            "cache_read_input" => 0.2,
            "batch_input" => 1.0,
            "batch_output" => 4.0,
            "batch_cache_read_input" => 0.1,
            "_context_price_threshold_tokens" => 200_000,
            "above_context_input" => 4.0,
            "above_context_output" => 12.0,
            "above_context_cache_read_input" => 0.4,
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
        pricing_mode: "batch"
      )

      expect(result.components.fetch(:input_cost)).to eq(0.3)
      expect(result.components.fetch(:cache_read_input_cost)).to eq(0.012)
      expect(result.components.fetch(:output_cost)).to eq(0.6)
      expect(result.total).to eq(0.912)
    end

    it "prices the long-context input only when the long-context output rate is missing" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "incomplete-tier-model" => {
            "input" => 1.0,
            "output" => 2.0,
            "_context_price_threshold_tokens" => 200_000,
            "above_context_input" => 3.0
          }
        }
      end

      result = cost_for(
        provider: "custom",
        model: "incomplete-tier-model",
        input_tokens: 250_000,
        output_tokens: 100_000
      )

      expect(result).to have_attributes(total: 0.75, components: include(input_cost: 0.75))
      expect(result.components).not_to have_key(:output_cost)
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

        expect(result.components.fetch(:input_cost)).to eq(9.0)
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
            "my-custom-model" => { "input" => 1.0, "output" => 2.0 }
          }
        end

        result = cost_for(
          provider: "custom",
          model: "my-custom-model",
          input_tokens: 1_000_000,
          output_tokens: 1_000_000
        )

        expect(result.components.fetch(:input_cost)).to eq(1.0)
        expect(result.components.fetch(:output_cost)).to eq(2.0)
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

        expect(result.components.fetch(:input_cost)).to eq(3.0)
        expect(result.components.fetch(:output_cost)).to eq(4.0)
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
          "deepseek-chat" => { "input" => 0.27, "output" => 1.10 },
          "deepseek/deepseek-chat" => { "input" => 0.20, "output" => 0.90 }
        }
      end

      result = cost_for(
        provider: "deepseek",
        model: "deepseek-chat",
        input_tokens: 1_000_000,
        output_tokens: 1_000_000
      )

      expect(result.components.fetch(:input_cost)).to eq(0.2)
      expect(result.components.fetch(:output_cost)).to eq(0.9)
    end
  end

  describe "lookup cache" do
    it "returns consistent sorted keys under concurrent lookup" do
      if LlmCostTracker::Pricing::Registry.instance_variable_defined?(:@sorted_price_keys_cache)
        LlmCostTracker::Pricing::Registry.remove_instance_variable(:@sorted_price_keys_cache)
      end

      table = {
        "gpt-4" => { "input" => 30.0, "output" => 60.0 },
        "gpt-4o" => { "input" => 2.5, "output" => 10.0 }
      }

      results = 10.times.map do
        Thread.new { LlmCostTracker::Pricing::Registry.send(:sorted_price_keys, table) }
      end.map(&:value)

      expect(results).to all(eq(%w[gpt-4o gpt-4]))
    end

    it "invalidates cached matches when configuration resets" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "custom/cached-model" => { "input" => 1.0, "output" => 2.0 }
        }
      end

      expect(
        cost_for(provider: "custom", model: "cached-model", input_tokens: 1_000_000, output_tokens: 0)
      ).to have_attributes(components: include(input_cost: 1.0))

      LlmCostTrackerReset.call
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "custom/cached-model" => { "input" => 3.0, "output" => 4.0 }
        }
      end

      expect(
        cost_for(provider: "custom", model: "cached-model", input_tokens: 1_000_000, output_tokens: 0)
      ).to have_attributes(components: include(input_cost: 3.0))
    end

    it "caches configured price files between lookups" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write(JSON.generate("models" => {
                                   "cached-file-model" => { "input" => 9.0, "output" => 10.0 }
                                 }))
        file.close

        LlmCostTracker.configure { |c| c.prices_file = file.path }
        allow(LlmCostTracker::Pricing::Registry).to receive(:file_prices).and_call_original

        2.times { cost_for(provider: "custom", model: "cached-file-model", input_tokens: 1, output_tokens: 1) }

        expect(LlmCostTracker::Pricing::Registry).to have_received(:file_prices).once
      end
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
        next unless model_id.start_with?("anthropic/")
        next unless fields["input"] && fields["cache_read_input"]

        expected_ratio = model_id.end_with?("/claude-haiku-3") ? 0.12 : 0.1
        expect(fields["cache_read_input"]).to be_within(0.0001).of(fields["input"] * expected_ratio)
      end
    end

    it "holds the Anthropic extended cache-write pricing ratios" do
      bundled.each do |model_id, fields|
        next unless model_id.start_with?("anthropic/")

        expect(fields["cache_write_extended_input"]).to be_within(0.0001).of(fields["input"] * 2.0)
      end
    end

    it "holds the Anthropic default (5-minute) cache-write pricing ratios" do
      bundled.each do |model_id, fields|
        next unless model_id.start_with?("anthropic/")
        next unless fields["cache_write_input"] && fields["input"]

        expected_ratio = model_id.end_with?("/claude-haiku-3") ? 1.2 : 1.25
        expect(fields["cache_write_input"]).to be_within(0.0001).of(fields["input"] * expected_ratio)
      end
    end

    it "holds the Anthropic batch-discount invariant (50% of standard input/output)" do
      bundled.each do |model_id, fields|
        next unless model_id.start_with?("anthropic/")

        if fields["batch_input"] && fields["input"]
          expect(fields["batch_input"]).to be_within(0.0001).of(fields["input"] * 0.5)
        end
        if fields["batch_output"] && fields["output"]
          expect(fields["batch_output"]).to be_within(0.0001).of(fields["output"] * 0.5)
        end
      end
    end

    it "prices long context at a 2x input and 1.5x output premium" do
      thresholds = { "gemini" => 200_000, "openai" => 272_000 }
      long_context = bundled.select { |_model_id, fields| fields["_context_price_threshold_tokens"] }

      expect(long_context.keys.map { |model_id| model_id.split("/").first }.uniq).to match_array(thresholds.keys)
      long_context.each do |model_id, fields|
        provider = model_id.split("/").first

        expect(fields["_context_price_threshold_tokens"]).to eq(thresholds.fetch(provider))
        expect(fields).to include("above_context_input", "above_context_output")
        fields.keys.grep(/\Aabove_context_/).each do |key|
          base = fields.fetch(key.delete_prefix("above_context_"))
          premium = base * (key.end_with?("output") ? 1.5 : 2)
          matcher = key.include?("cache") ? be_within(5).percent_of(premium) : be_within(0.0001).of(premium)
          expect(fields[key]).to matcher, "#{model_id}.#{key}"
        end
      end
    end

    it "holds the OpenAI cache-write pricing ratio (1.25x input)" do
      bundled.each do |model_id, fields|
        next unless model_id.start_with?("openai/")
        next unless fields["cache_write_input"] && fields["input"]

        expect(fields["cache_write_input"]).to be_within(0.0001).of(fields["input"] * 1.25)
      end
    end

    it "keeps Groq prompt cache reads at 50% of input pricing" do
      bundled.each do |model_id, fields|
        next unless model_id.start_with?("groq/")
        next unless fields["cache_read_input"]

        expect(fields["cache_read_input"]).to be_within(0.0001).of(fields["input"] * 0.5)
      end
    end

    it "keeps Groq flex token pricing equal to on-demand pricing" do
      bundled.each do |model_id, fields|
        next unless model_id.start_with?("groq/")
        next unless fields["flex_input"]

        expect(fields["flex_input"]).to eq(fields["on_demand_input"])
        expect(fields["flex_output"]).to eq(fields["on_demand_output"])
        if fields["flex_cache_read_input"]
          expect(fields["flex_cache_read_input"]).to eq(fields["on_demand_cache_read_input"])
        end
      end
    end

    it "keeps output more expensive than input for chat-style models" do
      non_chat = /embed|audio|whisper|tts|image|moderation|guard/
      bundled.each do |model_id, fields|
        next if model_id.start_with?("openrouter/")
        next if model_id.match?(non_chat)
        next unless fields["input"] && fields["output"]

        expect(fields["output"]).to be > fields["input"]
      end
    end
  end
end
