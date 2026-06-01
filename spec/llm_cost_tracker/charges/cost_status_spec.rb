# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Charges::CostStatus do
  let(:token_usage) { LlmCostTracker::Usage::TokenUsage.build(input_tokens: 0, output_tokens: 0) }

  def service_line_item(dimension_key: "web_search_request", quantity: 1, cost: nil, cost_status: nil)
    LlmCostTracker::Charges::LineItem.build(
      dimension_key: dimension_key,
      quantity: quantity,
      cost: cost,
      cost_status: cost_status
    )
  end

  it "ignores non-billable service charges" do
    status = described_class.call(
      token_usage: token_usage,
      usage_source: "manual",
      token_cost: nil,
      service_line_items: [
        service_line_item(quantity: 0, cost_status: described_class::UNKNOWN)
      ],
      total_cost: nil
    )

    expect(status).to eq(described_class::FREE)
  end

  it "stops scanning service charges after priced and unpriced usage are both known" do
    status = described_class.call(
      token_usage: token_usage,
      usage_source: "manual",
      token_cost: nil,
      service_line_items: [
        service_line_item(cost: 0.01),
        service_line_item(cost_status: described_class::UNKNOWN),
        service_line_item(cost: 0.02)
      ],
      total_cost: 0.01
    )

    expect(status).to eq(described_class::PARTIAL)
  end

  it "treats nil total cost with no billable usage as free" do
    status = described_class.call(
      token_usage: token_usage,
      usage_source: "manual",
      token_cost: nil,
      service_line_items: [],
      total_cost: nil
    )

    expect(status).to eq(described_class::FREE)
  end

  it "marks token pricing partial when some token components were priced and others were not" do
    billable_usage = LlmCostTracker::Usage::TokenUsage.build(input_tokens: 1_000, output_tokens: 1_000)

    status = described_class.call(
      token_usage: billable_usage,
      usage_source: "response",
      token_cost: { input_cost: 0.01, total_cost: 0.01 },
      token_pricing_partial: true,
      service_line_items: [],
      total_cost: 0.01
    )

    expect(status).to eq(described_class::PARTIAL)
  end

  it "marks fully-priced billable usage as complete" do
    billable_usage = LlmCostTracker::Usage::TokenUsage.build(input_tokens: 1_000, output_tokens: 500)

    status = described_class.call(
      token_usage: billable_usage,
      usage_source: "response",
      token_cost: { input_cost: 0.01, output_cost: 0.02, total_cost: 0.03 },
      service_line_items: [],
      total_cost: 0.03
    )

    expect(status).to eq(described_class::COMPLETE)
  end

  it "returns unknown when usage source is unknown" do
    status = described_class.call(
      token_usage: token_usage,
      usage_source: "unknown",
      token_cost: nil,
      service_line_items: [],
      total_cost: nil
    )

    expect(status).to eq(described_class::UNKNOWN)
  end

  it "returns unknown when only billable usage is unpriced and nothing else is priced" do
    billable_usage = LlmCostTracker::Usage::TokenUsage.build(input_tokens: 100, output_tokens: 0)

    status = described_class.call(
      token_usage: billable_usage,
      usage_source: "response",
      token_cost: nil,
      service_line_items: [],
      total_cost: nil
    )

    expect(status).to eq(described_class::UNKNOWN)
  end
end
