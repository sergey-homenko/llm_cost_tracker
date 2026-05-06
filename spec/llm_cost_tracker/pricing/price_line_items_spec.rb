# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Pricing do
  describe ".price_line_items" do
    let(:input_token) do
      LlmCostTracker::Billing::LineItem.build(
        kind: :text_token,
        direction: :input,
        modality: :text,
        cache_state: :none,
        quantity: 1_000_000,
        unit: :token
      )
    end

    let(:output_token) do
      LlmCostTracker::Billing::LineItem.build(
        kind: :text_token,
        direction: :output,
        modality: :text,
        cache_state: :none,
        quantity: 1_000_000,
        unit: :token
      )
    end

    let(:web_search) do
      LlmCostTracker::Billing::LineItem.build(
        kind: :web_search_request,
        direction: :neither,
        modality: :text,
        cache_state: :none,
        quantity: 5,
        unit: :request,
        cost_status: LlmCostTracker::Billing::CostStatus::UNKNOWN
      )
    end

    it "prices token line items using the bundled registry" do
      priced, snapshot = described_class.price_line_items(
        provider: :openai,
        model: "gpt-4o",
        line_items: [input_token, output_token]
      )

      expect(priced.first.cost.to_f).to eq(2.5)
      expect(priced.last.cost.to_f).to eq(10.0)
      expect(priced.first.rate_amount.to_f).to eq(2.5)
      expect(priced.first.rate_quantity.to_i).to eq(1_000_000)
      expect(priced.first.price_key).to eq(:input)
      expect(snapshot.fetch(:source)).to eq(:bundled)
    end

    it "prices service charge line items via Pricing.charge_rate" do
      priced, _snapshot = described_class.price_line_items(
        provider: :anthropic,
        model: "claude-sonnet-4-6",
        line_items: [web_search]
      )

      charge = priced.first
      expect(charge.cost.to_f).to eq(0.05)
      expect(charge.cost_status).to eq(LlmCostTracker::Billing::CostStatus::COMPLETE)
      expect(charge.rate_amount.to_f).to eq(10.0)
    end

    it "marks token line items as unknown when the model is missing" do
      priced, snapshot = described_class.price_line_items(
        provider: :missing,
        model: "no-such-model",
        line_items: [input_token]
      )

      expect(priced.first.cost_status).to eq(LlmCostTracker::Billing::CostStatus::UNKNOWN)
      expect(snapshot).to be_nil
    end

    it "skips service charge line items that are already priced" do
      already_priced = LlmCostTracker::Billing::LineItem.build(
        kind: :web_search_request,
        direction: :neither,
        modality: :text,
        cache_state: :none,
        quantity: 1,
        unit: :request,
        cost: 0.01,
        cost_status: LlmCostTracker::Billing::CostStatus::COMPLETE
      )

      priced, _snapshot = described_class.price_line_items(
        provider: :anthropic,
        model: "claude-sonnet-4-6",
        line_items: [already_priced]
      )

      expect(priced.first.cost.to_f).to eq(0.01)
    end

    it "skips zero-quantity service charge line items" do
      empty_charge = LlmCostTracker::Billing::LineItem.build(
        kind: :web_search_request,
        direction: :neither,
        modality: :text,
        cache_state: :none,
        quantity: 0,
        unit: :request,
        cost_status: LlmCostTracker::Billing::CostStatus::UNKNOWN
      )

      priced, _snapshot = described_class.price_line_items(
        provider: :anthropic,
        model: "claude-sonnet-4-6",
        line_items: [empty_charge]
      )

      expect(priced.first.cost).to be_nil
      expect(priced.first.cost_status).to eq(LlmCostTracker::Billing::CostStatus::UNKNOWN)
    end

    it "leaves service charge line items unpriced when no rate exists" do
      grounding = LlmCostTracker::Billing::LineItem.build(
        kind: :grounding_request,
        direction: :neither,
        modality: :text,
        cache_state: :none,
        quantity: 1,
        unit: :request,
        cost_status: LlmCostTracker::Billing::CostStatus::UNKNOWN
      )

      priced, _snapshot = described_class.price_line_items(
        provider: :gemini,
        model: "gemini-2.5-flash",
        line_items: [grounding]
      )

      expect(priced.first.cost_status).to eq(LlmCostTracker::Billing::CostStatus::UNKNOWN)
      expect(priced.first.cost).to be_nil
    end

    it "passes through token line items with attributes outside the component registry" do
      orphan = LlmCostTracker::Billing::LineItem.build(
        kind: :unknown_token, direction: :input, modality: :video, cache_state: :none,
        quantity: 100, unit: :token
      )

      priced, _snapshot = described_class.price_line_items(
        provider: :openai,
        model: "gpt-4o",
        line_items: [orphan]
      )

      expect(priced.first.cost).to be_nil
      expect(priced.first.price_key).to be_nil
    end

    it "marks token line items as unknown when the model lacks a component rate" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = { "custom/partial" => { input: 1.0 } }
      end

      input_li = LlmCostTracker::Billing::LineItem.build(
        kind: :text_token, direction: :input, modality: :text, cache_state: :none,
        quantity: 500, unit: :token
      )
      output_li = LlmCostTracker::Billing::LineItem.build(
        kind: :text_token, direction: :output, modality: :text, cache_state: :none,
        quantity: 1_000, unit: :token
      )

      priced, snapshot = described_class.price_line_items(
        provider: :custom,
        model: "partial",
        line_items: [input_li, output_li]
      )

      expect(snapshot).not_to be_nil
      expect(priced.first.cost.to_f).to eq(0.0005)
      expect(priced.last.cost_status).to eq(LlmCostTracker::Billing::CostStatus::UNKNOWN)
      expect(priced.last.cost).to be_nil
    end

    it "marks token line items as FREE when the registry rate is zero" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = { "custom/free-cache" => { input: 1.0, output: 1.0, cache_read_input: 0.0 } }
      end

      cache_read = LlmCostTracker::Billing::LineItem.build(
        kind: :text_token, direction: :input, modality: :text, cache_state: :read,
        quantity: 1_000_000, unit: :token
      )

      priced, _snapshot = described_class.price_line_items(
        provider: :custom,
        model: "free-cache",
        line_items: [cache_read]
      )

      expect(priced.first.cost.to_f).to eq(0.0)
      expect(priced.first.cost_status).to eq(LlmCostTracker::Billing::CostStatus::FREE)
      expect(priced.first.price_source).to eq(:pricing_overrides)
    end
  end
end
