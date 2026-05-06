# frozen_string_literal: true

require "spec_helper"

require_relative "../../dummy/config/environment"

RSpec.describe LlmCostTracker::Doctor::CostDriftCheck do
  include_context "with mounted llm cost tracker engine"

  it "is skipped when the calls table is missing" do
    allow(LlmCostTracker::Doctor::Probe).to receive(:table_exists?)
      .with("llm_cost_tracker_calls").and_return(false)

    expect(described_class.new.call).to be_nil
  end

  it "is skipped when the line items table is missing" do
    allow(LlmCostTracker::Doctor::Probe).to receive(:table_exists?).and_call_original
    allow(LlmCostTracker::Doctor::Probe).to receive(:table_exists?)
      .with("llm_cost_tracker_call_line_items").and_return(false)

    expect(described_class.new.call).to be_nil
  end

  it "reports ok when there are no priced calls" do
    expect(described_class.new.call)
      .to have_attributes(status: :ok, message: include("no priced calls"))
  end

  it "reports ok when header total matches line items" do
    create_call(
      input_tokens: 1_000,
      output_tokens: 500,
      total_cost: BigDecimal("0.001500")
    )
    line_items_for_last_call(
      [{ kind: "text_token", direction: "input", quantity: 1_000, cost: BigDecimal("0.001000") },
       { kind: "text_token", direction: "output", quantity: 500, cost: BigDecimal("0.000500") }]
    )

    expect(described_class.new.call)
      .to have_attributes(status: :ok, message: include("matches line items"))
  end

  it "warns when header total drifts from line items" do
    create_call(
      input_tokens: 1_000,
      output_tokens: 500,
      total_cost: BigDecimal("0.001500")
    )
    line_items_for_last_call(
      [{ kind: "text_token", direction: "input", quantity: 1_000, cost: BigDecimal("0.000900") }]
    )

    expect(described_class.new.call)
      .to have_attributes(status: :warn, message: include("diverges from line items"))
  end

  it "tolerates partial calls where header is at-or-above line items sum" do
    create_call(
      input_tokens: 1_000,
      output_tokens: 500,
      total_cost: BigDecimal("0.001500"),
      cost_status: LlmCostTracker::Billing::CostStatus::PARTIAL
    )
    line_items_for_last_call(
      [{ kind: "text_token", direction: "input", quantity: 1_000, cost: BigDecimal("0.000400") }]
    )

    expect(described_class.new.call).to have_attributes(status: :ok)
  end

  def line_items_for_last_call(rows)
    call = LlmCostTracker::Call.order(:id).last
    rows.each.with_index do |attrs, index|
      LlmCostTracker::CallLineItem.create!(
        llm_cost_tracker_call_id: call.id,
        position: index,
        kind: attrs.fetch(:kind),
        direction: attrs.fetch(:direction),
        modality: "text",
        cache_state: "none",
        unit: "token",
        quantity: attrs.fetch(:quantity),
        rate_amount: BigDecimal("1.0"),
        rate_quantity: BigDecimal("1000000"),
        cost: attrs.fetch(:cost),
        currency: "USD",
        cost_status: LlmCostTracker::Billing::CostStatus::COMPLETE,
        pricing_basis: "rate_table",
        details: {}
      )
    end
  end
end
