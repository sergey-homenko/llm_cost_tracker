# frozen_string_literal: true

require "spec_helper"

require_relative "../dummy/config/environment"
require_relative "../../app/models/llm_cost_tracker/provider_invoice_import"

RSpec.describe LlmCostTracker::ProviderInvoiceImport do
  include_context "with mounted llm cost tracker engine"
  include_context "with reconciliation enabled"

  def build_import(state:, source: "openai", provider: "", cursor: nil, started_at: Time.now.utc,
                   window_start: nil, window_end: nil)
    described_class.create!(
      source: source,
      provider: provider,
      cursor: cursor,
      window_start: window_start,
      window_end: window_end,
      state: state,
      started_at: started_at
    )
  end

  it "scopes by source through .for_source" do
    build_import(state: described_class::STATE_COMPLETED, source: "openai")
    build_import(state: described_class::STATE_COMPLETED, source: "anthropic")

    expect(described_class.for_source(:openai).count).to eq(1)
  end

  it "exposes lifecycle scopes for running, completed, and failed imports" do
    build_import(state: described_class::STATE_RUNNING)
    build_import(state: described_class::STATE_COMPLETED)
    build_import(state: described_class::STATE_FAILED)

    expect(described_class.running.count).to eq(1)
    expect(described_class.completed.count).to eq(1)
    expect(described_class.failed.count).to eq(1)
  end

  describe ".resume_cursor_for" do
    it "returns the cursor of the most recent import for the source" do
      build_import(state: described_class::STATE_COMPLETED, source: "openai", cursor: "page-1",
                   started_at: 2.days.ago)
      build_import(state: described_class::STATE_FAILED, source: "openai", cursor: "page-2",
                   started_at: 1.day.ago)

      expect(described_class.resume_cursor_for("openai")).to eq("page-2")
    end

    it "returns nil when no import exists for the source" do
      expect(described_class.resume_cursor_for("openai")).to be_nil
    end
  end

  describe ".last_completed_window_for" do
    it "returns the window of the latest completed import" do
      build_import(state: described_class::STATE_FAILED, cursor: "fail",
                   window_start: Date.new(2026, 4, 1), window_end: Date.new(2026, 4, 30))
      build_import(state: described_class::STATE_COMPLETED,
                   window_start: Date.new(2026, 5, 1), window_end: Date.new(2026, 5, 31))

      expect(described_class.last_completed_window_for("openai"))
        .to eq([Date.new(2026, 5, 1), Date.new(2026, 5, 31)])
    end

    it "returns nil when no completed import exists for the source" do
      build_import(state: described_class::STATE_FAILED)

      expect(described_class.last_completed_window_for("openai")).to be_nil
    end

    it "isolates per-provider when the provider keyword is supplied" do
      build_import(state: described_class::STATE_COMPLETED, source: "csv", provider: "openai",
                   window_start: Date.new(2026, 4, 1), window_end: Date.new(2026, 4, 30),
                   started_at: 2.days.ago)
      build_import(state: described_class::STATE_COMPLETED, source: "csv", provider: "anthropic",
                   window_start: Date.new(2026, 5, 1), window_end: Date.new(2026, 5, 31),
                   started_at: 1.day.ago)

      expect(described_class.last_completed_window_for("csv", provider: "openai"))
        .to eq([Date.new(2026, 4, 1), Date.new(2026, 4, 30)])
      expect(described_class.last_completed_window_for("csv", provider: "anthropic"))
        .to eq([Date.new(2026, 5, 1), Date.new(2026, 5, 31)])
    end
  end
end
