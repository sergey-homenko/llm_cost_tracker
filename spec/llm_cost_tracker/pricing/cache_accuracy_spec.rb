# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Cache-aware cost accuracy" do
  def cost_for(provider:, model:, pricing_mode: nil, **usage)
    LlmCostTracker::Pricing.cost_for(
      provider: provider,
      model: model,
      pricing_mode: pricing_mode,
      tokens: LlmCostTracker::Usage::TokenUsage.build(**usage)
    )
  end

  describe "LiteLLM #19681 regression: cached_tokens billed at cache_read rate, not full input rate" do
    it "applies input rate only to the non-cached portion of prompt_tokens" do
      LlmCostTracker.configure do |c|
        c.pricing.overrides = { "demo/glm-pattern" => { input: 0.6, output: 2.2, cache_read_input: 0.075 } }
      end

      result = cost_for(
        provider: "demo",
        model: "glm-pattern",
        input_tokens: 761_469,
        cache_read_input_tokens: 7_715_693,
        output_tokens: 10_699
      )

      expect(result.components.fetch(:input_cost)).to be_within(0.0001).of(0.45688)
      expect(result.components.fetch(:cache_read_input_cost)).to be_within(0.0001).of(0.57868)
      expect(result.components.fetch(:output_cost)).to be_within(0.0001).of(0.02354)
      expect(result.total).to be_within(0.0001).of(1.05910)
    end

    it "would charge 10.9x more if input rate were applied to the whole prompt (the bug we avoid)" do
      LlmCostTracker.configure do |c|
        c.pricing.overrides = { "demo/glm-pattern" => { input: 0.6, output: 2.2, cache_read_input: 0.075 } }
      end

      bug_total = BigDecimal("8477162") * BigDecimal("0.6") / 1_000_000 +
                  BigDecimal("10699") * BigDecimal("2.2") / 1_000_000

      correct = cost_for(
        provider: "demo",
        model: "glm-pattern",
        input_tokens: 761_469,
        cache_read_input_tokens: 7_715_693,
        output_tokens: 10_699
      ).total

      expect((bug_total.to_f / correct.to_f)).to be > 4.0
    end
  end

  describe "LiteLLM #27191 regression: pricing_overrides cache_read_input is honored, not ignored" do
    it "uses cache_read_input rate from pricing_overrides instead of falling back to input rate" do
      LlmCostTracker.configure do |c|
        c.pricing.overrides = { "demo/custom" => { input: 2.5, output: 10.0, cache_read_input: 0.25 } }
      end

      result = cost_for(
        provider: "demo",
        model: "custom",
        input_tokens: 2618,
        cache_read_input_tokens: 3456,
        output_tokens: 285
      )

      expect(result.components.fetch(:input_cost)).to be_within(0.000001).of(0.006545)
      expect(result.components.fetch(:cache_read_input_cost)).to be_within(0.000001).of(0.000864)
      expect(result.components.fetch(:output_cost)).to be_within(0.000001).of(0.002850)
      expect(result.total).to be_within(0.000001).of(0.010259)
    end

    it "would charge ~67% more if cache_read_input override were ignored (the bug we avoid)" do
      LlmCostTracker.configure do |c|
        c.pricing.overrides = { "demo/custom" => { input: 2.5, output: 10.0, cache_read_input: 0.25 } }
      end

      bug_total = BigDecimal("6074") * BigDecimal("2.5") / 1_000_000 +
                  BigDecimal("285") * BigDecimal("10.0") / 1_000_000

      correct = cost_for(
        provider: "demo",
        model: "custom",
        input_tokens: 2618,
        cache_read_input_tokens: 3456,
        output_tokens: 285
      ).total

      expect((bug_total.to_f / correct.to_f)).to be > 1.5
    end
  end

  describe "Anthropic 5-min vs 1-hour cache write tier routing" do
    it "prices ephemeral_5m_input at cache_write_input rate and ephemeral_1h_input at cache_write_extended_input rate" do
      LlmCostTracker.configure do |c|
        c.pricing.overrides = {
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

      expect(result.components.fetch(:cache_write_input_cost)).to be_within(0.0001).of(1.125)
      expect(result.components.fetch(:cache_write_extended_input_cost)).to be_within(0.0001).of(2.4)
      expect(result.total).to be_within(0.0001).of(0.3 + 0.06 + 1.125 + 2.4 + 0.15)
    end

  end

  describe "OpenAI cache tokens on a model without a cache rate" do
    it "prices Pro cache hits at the input rate of the mode and context tier, as Pro has no cached discount" do
      standard = cost_for(provider: "openai", model: "gpt-5.5-pro",
                          input_tokens: 3616, cache_read_input_tokens: 16_384, output_tokens: 3000)
      residency = cost_for(provider: "openai", model: "gpt-5.5-pro", pricing_mode: "data_residency",
                           input_tokens: 3616, cache_read_input_tokens: 16_384, output_tokens: 3000)
      long_context = cost_for(provider: "openai", model: "gpt-5.5-pro",
                              input_tokens: 99_936, cache_read_input_tokens: 200_064, output_tokens: 1000)

      expect([standard.total, residency.total, long_context.total])
        .to eq([BigDecimal("1.14"), BigDecimal("1.254"), BigDecimal("18.27")])
    end

    it "prices cache writes before GPT-5.6 at the input rate and keeps the GPT-5.6 cache-write rate" do
      before_writes = cost_for(provider: "openai", model: "gpt-5.5",
                               input_tokens: 2952, cache_write_input_tokens: 2048, output_tokens: 100)
      with_writes = cost_for(provider: "openai", model: "gpt-5.6-sol",
                             input_tokens: 2952, cache_write_input_tokens: 2048, output_tokens: 100)

      expect([before_writes.total, with_writes.total]).to eq([BigDecimal("0.028"), BigDecimal("0.024048")])
    end

    it "leaves cache hits unpriced for a pricing.overrides entry without a cache rate" do
      LlmCostTracker.configure { |c| c.pricing.overrides = { "openai/gpt-4o" => { input: 2.5, output: 10.0 } } }

      result = cost_for(provider: "openai", model: "gpt-4o",
                        input_tokens: 1000, cache_read_input_tokens: 2000, output_tokens: 400)

      expect(result.components[:cache_read_input_cost]).to be_nil
      expect(result.total).to eq(BigDecimal("0.0065"))
    end
  end
end
