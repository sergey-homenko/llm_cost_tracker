# frozen_string_literal: true

require "spec_helper"

require_relative "../dummy/config/environment"

RSpec.describe LlmCostTracker::Reconciliation do
  include_context "with mounted llm cost tracker engine"

  let(:rows) do
    [
      {
        external_id: "openai-row-1",
        period_start: "2026-05-01",
        period_end: "2026-05-31",
        billed_amount: "12.34",
        currency: "USD",
        metadata: { provider_project_id: "proj_a", model: "gpt-4o" }
      },
      {
        external_id: "openai-row-2",
        period_start: Date.new(2026, 5, 1),
        period_end: Date.new(2026, 5, 31),
        billed_amount: 0.5,
        metadata: nil
      }
    ]
  end

  describe ".import" do
    it "inserts a row per provider invoice line, idempotent on external_id" do
      result = described_class.import(source: :openai, rows: rows)

      expect(result.inserted).to eq(2)
      expect(result.updated).to eq(0)
      expect(result.skipped).to eq(0)
      expect(result).to be_success
      expect(LlmCostTracker::ProviderInvoice.count).to eq(2)

      first = LlmCostTracker::ProviderInvoice.find_by!(external_id: "openai-row-1")
      expect(first.source).to eq("openai")
      expect(first.billed_amount).to eq(BigDecimal("12.34"))
      expect(first.currency).to eq("USD")
      expect(first.period_start).to eq(Date.new(2026, 5, 1))
      expect(first.metadata).to include("provider_project_id" => "proj_a")
    end

    it "updates existing rows when re-imported with the same external_id" do
      described_class.import(source: :openai, rows: rows)
      updated = rows.first.merge(billed_amount: "99.99", metadata: { note: "refund" })

      result = described_class.import(source: :openai, rows: [updated])

      expect(result.inserted).to eq(0)
      expect(result.updated).to eq(1)
      reloaded = LlmCostTracker::ProviderInvoice.find_by!(external_id: "openai-row-1")
      expect(reloaded.billed_amount).to eq(BigDecimal("99.99"))
      expect(reloaded.metadata).to eq("note" => "refund")
    end

    it "defaults currency to USD when not provided" do
      described_class.import(source: :openai, rows: rows)

      second = LlmCostTracker::ProviderInvoice.find_by!(external_id: "openai-row-2")
      expect(second.currency).to eq("USD")
    end

    it "skips rows missing required fields and reports them in errors" do
      malformed = [{ external_id: "missing-period", billed_amount: "1.0" }]

      result = described_class.import(source: :openai, rows: malformed)

      expect(result.inserted).to eq(0)
      expect(result.skipped).to eq(1)
      expect(result.errors.first).to include("missing period_start, period_end")
      expect(LlmCostTracker::ProviderInvoice.count).to eq(0)
    end

    it "is a no-op for empty input" do
      result = described_class.import(source: :openai, rows: [])

      expect(result.total_imported).to eq(0)
      expect(LlmCostTracker::ProviderInvoice.count).to eq(0)
    end

    it "rejects an empty source" do
      expect { described_class.import(source: "", rows: rows) }
        .to raise_error(ArgumentError, /source must be present/)
    end
  end
end
