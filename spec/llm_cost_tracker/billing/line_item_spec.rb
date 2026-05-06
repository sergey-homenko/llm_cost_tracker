# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Billing::LineItem do
  describe ".build" do
    it "marks zero-cost token line items as FREE" do
      line_item = described_class.build(
        kind: :text_token, direction: :input, modality: :text, cache_state: :none,
        quantity: 100, unit: :token, cost: 0
      )
      expect(line_item.cost_status).to eq(LlmCostTracker::Billing::CostStatus::FREE)
    end

    it "fills attributes from a known component when given a component key" do
      line_item = described_class.build(quantity: 1, component_key: :web_search_request)
      expect(line_item.kind).to eq(:web_search_request)
      expect(line_item.unit).to eq(:request)
      expect(line_item.modality).to eq(:text)
    end

    it "normalizes symbol cost_status to string so predicates match" do
      line_item = described_class.build(
        component_key: :web_search_request, quantity: 1, cost_status: :unknown
      )

      expect(line_item.cost_status).to eq(LlmCostTracker::Billing::CostStatus::UNKNOWN)
      expect(line_item).to be_unpriced
      expect(line_item).not_to be_priced
    end

    it "coerces symbol-typed attributes from strings" do
      line_item = described_class.build(
        kind: "text_token", direction: "output", modality: "text", cache_state: "none",
        quantity: 1, unit: "token", price_source: "bundled"
      )
      expect(line_item.kind).to eq(:text_token)
      expect(line_item.price_source).to eq(:bundled)
    end
  end

  describe "predicates" do
    let(:priced) do
      described_class.build(
        kind: :text_token, direction: :input, modality: :text, cache_state: :none,
        quantity: 100, unit: :token, cost: 0.5,
        cost_status: LlmCostTracker::Billing::CostStatus::COMPLETE
      )
    end

    let(:unpriced) do
      described_class.build(
        kind: :web_search_request, direction: :neither, modality: :text, cache_state: :none,
        quantity: 1, unit: :request,
        cost_status: LlmCostTracker::Billing::CostStatus::UNKNOWN
      )
    end

    it "exposes priced/unpriced/token/billable predicates" do
      expect(priced).to be_priced
      expect(priced).to be_token
      expect(priced).to be_billable
      expect(unpriced).to be_unpriced
      expect(unpriced).not_to be_token
    end

    it "returns zero cost_value when cost is missing" do
      expect(unpriced.cost_value.to_f).to eq(0.0)
    end
  end

  describe "#to_h" do
    it "serializes BigDecimal fields as strings" do
      line_item = described_class.build(
        kind: :text_token, direction: :input, modality: :text, cache_state: :none,
        quantity: 100, unit: :token, cost: 0.123456789
      )
      hash = line_item.to_h
      expect(hash[:quantity]).to eq("100.0")
      expect(hash[:cost]).to start_with("0.12345")
    end
  end
end
