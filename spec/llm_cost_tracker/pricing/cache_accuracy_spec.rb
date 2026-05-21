# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Cache-aware cost accuracy" do
  def cost_for(provider:, model:, pricing_mode: nil, **usage)
    LlmCostTracker::Pricing.cost_for(
      provider: provider,
      model: model,
      pricing_mode: pricing_mode,
      tokens: LlmCostTracker::TokenUsage.build(**usage)
    )
  end

  describe "LiteLLM #19681 regression: cached_tokens billed at cache_read rate, not full input rate" do
    it "applies input rate only to the non-cached portion of prompt_tokens" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = { "demo/glm-pattern" => { input: 0.6, output: 2.2, cache_read_input: 0.075 } }
      end

      result = cost_for(
        provider: "demo",
        model: "glm-pattern",
        input_tokens: 761_469,
        cache_read_input_tokens: 7_715_693,
        output_tokens: 10_699
      )

      expect(result.fetch(:input_cost)).to be_within(0.0001).of(0.45688)
      expect(result.fetch(:cache_read_input_cost)).to be_within(0.0001).of(0.57868)
      expect(result.fetch(:output_cost)).to be_within(0.0001).of(0.02354)
      expect(result.fetch(:total_cost)).to be_within(0.0001).of(1.05910)
    end

    it "would charge 10.9x more if input rate were applied to the whole prompt (the bug we avoid)" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = { "demo/glm-pattern" => { input: 0.6, output: 2.2, cache_read_input: 0.075 } }
      end

      bug_total = BigDecimal("8477162") * BigDecimal("0.6") / 1_000_000 +
                  BigDecimal("10699") * BigDecimal("2.2") / 1_000_000

      correct = cost_for(
        provider: "demo",
        model: "glm-pattern",
        input_tokens: 761_469,
        cache_read_input_tokens: 7_715_693,
        output_tokens: 10_699
      ).fetch(:total_cost)

      expect((bug_total.to_f / correct.to_f)).to be > 4.0
    end
  end

  describe "LiteLLM #27191 regression: pricing_overrides cache_read_input is honored, not ignored" do
    it "uses cache_read_input rate from pricing_overrides instead of falling back to input rate" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = { "demo/custom" => { input: 2.5, output: 10.0, cache_read_input: 0.25 } }
      end

      result = cost_for(
        provider: "demo",
        model: "custom",
        input_tokens: 2618,
        cache_read_input_tokens: 3456,
        output_tokens: 285
      )

      expect(result.fetch(:input_cost)).to be_within(0.000001).of(0.006545)
      expect(result.fetch(:cache_read_input_cost)).to be_within(0.000001).of(0.000864)
      expect(result.fetch(:output_cost)).to be_within(0.000001).of(0.002850)
      expect(result.fetch(:total_cost)).to be_within(0.000001).of(0.010259)
    end

    it "would charge ~67% more if cache_read_input override were ignored (the bug we avoid)" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = { "demo/custom" => { input: 2.5, output: 10.0, cache_read_input: 0.25 } }
      end

      bug_total = BigDecimal("6074") * BigDecimal("2.5") / 1_000_000 +
                  BigDecimal("285") * BigDecimal("10.0") / 1_000_000

      correct = cost_for(
        provider: "demo",
        model: "custom",
        input_tokens: 2618,
        cache_read_input_tokens: 3456,
        output_tokens: 285
      ).fetch(:total_cost)

      expect((bug_total.to_f / correct.to_f)).to be > 1.5
    end
  end

  describe "Anthropic 5-min vs 1-hour cache write tier routing" do
    it "prices ephemeral_5m_input at cache_write_input rate and ephemeral_1h_input at cache_write_extended_input rate" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "anthropic/demo-tiered" => {
            input: 3.0,
            output: 15.0,
            cache_read_input: 0.3,
            cache_write_input: 3.75,
            cache_write_extended_input: 6.0
          }
        }
      end

      result = cost_for(
        provider: "anthropic",
        model: "demo-tiered",
        input_tokens: 100_000,
        cache_read_input_tokens: 200_000,
        cache_write_input_tokens: 300_000,
        cache_write_extended_input_tokens: 400_000,
        output_tokens: 10_000
      )

      expect(result.fetch(:cache_write_input_cost)).to be_within(0.0001).of(1.125)
      expect(result.fetch(:cache_write_extended_input_cost)).to be_within(0.0001).of(2.4)
      expect(result.fetch(:total_cost)).to be_within(0.0001).of(0.3 + 0.06 + 1.125 + 2.4 + 0.15)
    end

  end
end
