# frozen_string_literal: true

require "spec_helper"

require_relative "../../dummy/config/environment"

RSpec.describe LlmCostTracker::Doctor::PricingSnapshotDriftCheck do
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

  it "reports ok when there are no snapshotted complete calls" do
    expect(described_class.new.call)
      .to have_attributes(status: :ok, message: include("no snapshotted calls"))
  end

  it "reports ok when stored line item cost matches the snapshot rate" do
    create_call(
      input_tokens: 1_000,
      output_tokens: 500,
      total_cost: BigDecimal("0.001500"),
      pricing_snapshot: {
        "schema_version" => 1,
        "rates" => {
          "input" => { "amount" => 1.0, "quantity" => 1_000_000 },
          "output" => { "amount" => 1.0, "quantity" => 1_000_000 }
        }
      }
    )
    add_token_line_items(
      [
        { price_key: "input", direction: "input", quantity: 1_000, cost: BigDecimal("0.001000") },
        { price_key: "output", direction: "output", quantity: 500, cost: BigDecimal("0.000500") }
      ]
    )

    expect(described_class.new.call)
      .to have_attributes(status: :ok, message: include("match pricing_snapshot rates"))
  end

  it "warns when stored line item cost diverges from the snapshot rate" do
    create_call(
      input_tokens: 1_000,
      output_tokens: 0,
      total_cost: BigDecimal("0.000900"),
      pricing_snapshot: {
        "schema_version" => 1,
        "rates" => {
          "input" => { "amount" => 1.0, "quantity" => 1_000_000 }
        }
      }
    )
    add_token_line_items(
      [{ price_key: "input", direction: "input", quantity: 1_000, cost: BigDecimal("0.000900") }]
    )

    expect(described_class.new.call)
      .to have_attributes(status: :warn, message: include("diverges from pricing_snapshot"))
  end

  def add_token_line_items(rows)
    call = LlmCostTracker::Call.order(:id).last
    rows.each.with_index do |attrs, index|
      LlmCostTracker::CallLineItem.create!(
        llm_cost_tracker_call_id: call.id,
        position: index,
        kind: "text_token",
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
        price_key: attrs.fetch(:price_key),
        details: {}
      )
    end
  end
end
