# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Budget::Global do
  include_context "with mounted llm cost tracker engine"

  before do
    LlmCostTracker.configuration.ingestion.mode = :inline
    LlmCostTracker.configuration.pricing.unknown_model_behavior = :ignore
    LlmCostTracker.configuration.pricing.overrides = { "exact-model" => { input: 1.0 } }
    LlmCostTracker::Pricing::Registry.reset!
  end

  it "blocks a request once the month's spend has reached the monthly budget exactly" do
    LlmCostTracker.configuration.budgets.monthly = 10
    LlmCostTracker.configuration.budgets.exceeded_behavior = :block_requests
    allow(LlmCostTracker::Ledger::Period::Totals).to receive(:call).and_return(month: BigDecimal("10"))

    expect { LlmCostTracker::Budget.enforce!(provider: "openai", model: "unpriced-model", request: { "input" => "x" }) }
      .to raise_error(LlmCostTracker::BudgetExceededError)
  end

  it "raises after recording a call whose cost equals per_call" do
    LlmCostTracker.configuration.budgets.per_call = 1.0

    expect do
      LlmCostTracker.track(provider: "openai", model: "exact-model", tokens: { input_tokens: 1_000_000 },
                           enforce_budget: true)
    end.to raise_error(LlmCostTracker::BudgetExceededError)
  end

  it "blocks a request whose estimate equals per_call" do
    LlmCostTracker.configuration.budgets.per_call = 1.0
    LlmCostTracker.configuration.budgets.exceeded_behavior = :block_requests

    expect do
      LlmCostTracker::Budget.enforce!(provider: "openai", model: "exact-model", request: { "input" => "x" * 4_000_000 })
    end.to raise_error(LlmCostTracker::BudgetExceededError)
  end
end
