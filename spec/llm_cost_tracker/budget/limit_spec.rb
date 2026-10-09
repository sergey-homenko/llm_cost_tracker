# frozen_string_literal: true

require "spec_helper"
require "bigdecimal"
require "llm_cost_tracker/budget"

RSpec.describe LlmCostTracker::Budget::Limit do
  def limit(budget_type, budget, behavior: nil, on_exceeded: nil)
    described_class.new(budget_type: budget_type, budget: budget, scope: { key: "run_id", value: "r1" },
                        behavior: behavior, on_exceeded: on_exceeded)
  end

  it "is reached at its amount for spend and only past it for calls" do
    expect([limit(:daily, 5).over?(5), limit(:daily, 5).over?(4.99)]).to eq([true, false])
    expect([limit(:calls, 2).over?(2), limit(:calls, 2).over?(3)]).to eq([false, true])
  end

  it "charges a call its cost against spend and one against calls" do
    priced = Struct.new(:total_cost).new(BigDecimal("1.5"))
    unpriced = Struct.new(:total_cost).new(nil)

    expect([limit(:total, 5).charge(BigDecimal("1.5")), limit(:calls, 5).charge(BigDecimal("1.5"))]).to eq([1.5, 1])
    expect([limit(:total, 5).counts?(unpriced), limit(:total, 5).counts?(priced)]).to eq([false, true])
    expect(limit(:calls, 5).counts?(unpriced)).to be(true)
  end

  it "blocks pre-send with the scope it guards" do
    expect { limit(:calls, 2).block!(3) }.to raise_error(LlmCostTracker::BudgetExceededError) { |error|
      expect(error).to have_attributes(budget_type: :calls, total: 3, budget: 2, stage: :pre_send,
                                       scope: { key: "run_id", value: "r1" })
    }
  end

  it "notifies only the spend that crosses it and returns an error when its behavior raises" do
    notified = []
    crossing = limit(:total, 5, behavior: :raise, on_exceeded: ->(payload) { notified << payload[:total] })

    first = crossing.handle_exceeded(total: 6, previous_total: 4)
    second = crossing.handle_exceeded(total: 7, previous_total: 6)
    overridden = crossing.handle_exceeded(total: 8, previous_total: nil, behavior_override: :notify)

    expect(notified).to eq([6, 8])
    expect(first).to be_a(LlmCostTracker::BudgetExceededError).and(have_attributes(stage: :post_spend, total: 6))
    expect(second).to be_a(LlmCostTracker::BudgetExceededError)
    expect(overridden).to be_nil
  end

  it "falls back to the global behavior and callback" do
    notified = []
    LlmCostTracker.configure do |config|
      config.budgets.exceeded_behavior = :block_requests
      config.budgets.on_exceeded = ->(payload) { notified << payload[:budget_type] }
    end

    error = described_class.global(:monthly, 10).handle_exceeded(total: 12, previous_total: 9)

    expect(error).to have_attributes(budget_type: :monthly, scope: nil)
    expect(notified).to eq([:monthly])
  end

  it "counts a repriced call stamped at the window start toward that window" do
    change = Struct.new(:tracked_at, :total_cost).new(Time.utc(2026, 7, 1), BigDecimal("2"))

    expect(limit(:daily, 1).amount_in_window([change], Time.utc(2026, 7, 1, 12))).to eq(2)
  end
end
