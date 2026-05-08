# frozen_string_literal: true

require "spec_helper"

require_relative "../dummy/config/environment"

RSpec.describe LlmCostTracker::Reconciliation do
  include_context "with mounted llm cost tracker engine"

  let(:envelope) do
    { row_type: "cost", meter: "tokens", authority: "cost_api", match_basis: "period_only" }
  end

  let(:rows) do
    [
      {
        external_id: "row-1",
        period_start: "2026-05-01",
        period_end: "2026-05-31",
        billed_amount: "12.34",
        currency: "USD",
        metadata: envelope.merge(provider_project_id: "proj_a", model: "gpt-4o", match_basis: "project")
      },
      {
        external_id: "row-2",
        period_start: Date.new(2026, 5, 1),
        period_end: Date.new(2026, 5, 31),
        billed_amount: 0.5,
        metadata: envelope
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

      first = LlmCostTracker::ProviderInvoice.find_by!(external_id: "openai:row-1")
      expect(first.source).to eq("openai")
      expect(first.billed_amount).to eq(BigDecimal("12.34"))
      expect(first.currency).to eq("USD")
      expect(first.period_start).to eq(Date.new(2026, 5, 1))
      expect(first.metadata).to include("provider_project_id" => "proj_a")
    end

    it "namespaces external_id by source so colliding ids across providers stay separate" do
      described_class.import(source: :openai,    rows: [rows.first])
      described_class.import(source: :anthropic, rows: [rows.first])

      expect(LlmCostTracker::ProviderInvoice.pluck(:external_id))
        .to contain_exactly("openai:row-1", "anthropic:row-1")
    end

    it "does not double-prefix when the supplied id already carries the source prefix" do
      described_class.import(
        source: :openai,
        rows: [rows.first.merge(external_id: "openai:already-prefixed")]
      )

      expect(LlmCostTracker::ProviderInvoice.pluck(:external_id)).to eq(["openai:already-prefixed"])
    end

    it "updates existing rows when re-imported with the same external_id" do
      described_class.import(source: :openai, rows: rows)
      updated = rows.first.merge(
        billed_amount: "99.99",
        metadata: envelope.merge(note: "refund", match_basis: "period_only")
      )

      result = described_class.import(source: :openai, rows: [updated])

      expect(result.inserted).to eq(0)
      expect(result.updated).to eq(1)
      reloaded = LlmCostTracker::ProviderInvoice.find_by!(external_id: "openai:row-1")
      expect(reloaded.billed_amount).to eq(BigDecimal("99.99"))
      expect(reloaded.metadata).to include("note" => "refund")
    end

    it "defaults currency to USD when not provided" do
      described_class.import(source: :openai, rows: rows)

      second = LlmCostTracker::ProviderInvoice.find_by!(external_id: "openai:row-2")
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

    it "accepts string-keyed rows" do
      result = described_class.import(
        source: :openai,
        rows: [{
          "external_id" => "string-key-row",
          "period_start" => "2026-05-01",
          "period_end" => "2026-05-31",
          "billed_amount" => "1.00",
          "metadata" => envelope.transform_keys(&:to_s)
        }]
      )

      expect(result.inserted).to eq(1)
      expect(LlmCostTracker::ProviderInvoice.find_by!(external_id: "openai:string-key-row").billed_amount)
        .to eq(BigDecimal("1.00"))
    end

    it "parses metadata supplied as a JSON string" do
      described_class.import(
        source: :openai,
        rows: [{
          external_id: "string-metadata",
          period_start: "2026-05-01",
          period_end: "2026-05-31",
          billed_amount: "2.00",
          metadata: envelope.merge(provider_project_id: "proj_b", match_basis: "project").to_json
        }]
      )

      reloaded = LlmCostTracker::ProviderInvoice.find_by!(external_id: "openai:string-metadata")
      expect(reloaded.metadata).to include("provider_project_id" => "proj_b")
    end

    it "rejects invalid metadata JSON for provider-API sources rather than silently dropping evidence" do
      result = described_class.import(
        source: :openai,
        rows: [{
          external_id: "garbage-metadata",
          period_start: "2026-05-01",
          period_end: "2026-05-31",
          billed_amount: "0.5",
          metadata: "not-json"
        }]
      )

      expect(result.skipped).to eq(1)
      expect(result.errors.first).to include("invalid metadata JSON")
      expect(LlmCostTracker::ProviderInvoice.count).to eq(0)
    end

    it "is forgiving about invalid metadata JSON for the generic CSV source" do
      described_class.import(
        source: :csv,
        rows: [{
          external_id: "garbage-csv",
          period_start: "2026-05-01",
          period_end: "2026-05-31",
          billed_amount: "0.5",
          metadata: "not-json"
        }]
      )

      reloaded = LlmCostTracker::ProviderInvoice.find_by!(external_id: "csv:garbage-csv")
      expect(reloaded.metadata).to eq({})
    end

    it "rejects invalid metadata JSON for novel sources by default so attribution evidence is never silently dropped" do
      result = described_class.import(
        source: :novel_provider,
        rows: [{
          external_id: "row",
          period_start: "2026-05-01",
          period_end: "2026-05-31",
          metadata: "not-json"
        }]
      )

      expect(result.skipped).to eq(1)
      expect(result.errors.first).to include("invalid metadata JSON")
    end

    it "honours an explicit strict_metadata override over the per-source default" do
      result = LlmCostTracker::Reconciliation::Importer.new(
        source: :csv, imported_at: Time.now.utc, strict_metadata: true
      ).call([{
        external_id: "row",
        period_start: "2026-05-01",
        period_end: "2026-05-31",
        metadata: "not-json"
      }])

      expect(result.skipped).to eq(1)
      expect(result.errors.first).to include("invalid metadata JSON")
    end

    it "rejects metadata that starts using the envelope but leaves keys missing" do
      result = described_class.import(
        source: :openai,
        rows: [{
          external_id: "partial-envelope",
          period_start: "2026-05-01",
          period_end: "2026-05-31",
          billed_amount: "1.00",
          metadata: { row_type: "cost", meter: "tokens" }
        }]
      )

      expect(result.skipped).to eq(1)
      expect(result.errors.first).to include("metadata missing envelope keys")
      expect(result.errors.first).to include("authority")
      expect(result.errors.first).to include("match_basis")
    end

    it "accepts metadata with the full envelope" do
      result = described_class.import(
        source: :openai,
        rows: [{
          external_id: "full-envelope",
          period_start: "2026-05-01",
          period_end: "2026-05-31",
          billed_amount: "1.00",
          metadata: {
            row_type: "cost",
            meter: "tokens",
            authority: "cost_api",
            match_basis: "period_only"
          }
        }]
      )

      expect(result.inserted).to eq(1)
    end

    it "drops rows whose period falls entirely outside the configured window" do
      result = described_class.import(
        source: :openai,
        rows: [
          {
            external_id: "april", period_start: "2026-04-01", period_end: "2026-04-30",
            billed_amount: "1.00", metadata: envelope
          },
          {
            external_id: "may", period_start: "2026-05-01", period_end: "2026-05-31",
            billed_amount: "2.00", metadata: envelope
          }
        ],
        window: Date.new(2026, 5, 1)..Date.new(2026, 5, 31)
      )

      expect(result.inserted).to eq(1)
      expect(LlmCostTracker::ProviderInvoice.pluck(:external_id)).to eq(["openai:may"])
    end

    it "keeps rows whose period overlaps the window even partially" do
      result = described_class.import(
        source: :openai,
        rows: [{
          external_id: "boundary", period_start: "2026-04-15", period_end: "2026-05-15",
          billed_amount: "1.00", metadata: envelope
        }],
        window: Date.new(2026, 5, 1)..Date.new(2026, 5, 31)
      )

      expect(result.inserted).to eq(1)
    end

    it "rejects a non-Range window argument" do
      expect do
        described_class.import(source: :openai, rows: [], window: "2026-05")
      end.to raise_error(ArgumentError, /window must be a Range/)
    end
  end

  describe "configuration importers" do
    after { LlmCostTracker.configuration.reconciliation_importers = {} }

    it "stores callable importers under symbolised source keys" do
      callable = -> { :ok }
      LlmCostTracker.configuration.reconciliation_importers = { "openai" => callable }

      expect(LlmCostTracker.configuration.reconciliation_importers).to eq(openai: callable)
    end

    it "rejects importers that don't respond to call" do
      expect do
        LlmCostTracker.configuration.reconciliation_importers = { openai: "not callable" }
      end.to raise_error(LlmCostTracker::Error, /must respond to call/)
    end

    it "registers a block-style importer through the helper" do
      LlmCostTracker.configuration.register_reconciliation_importer(:anthropic) { :registered }

      importer = LlmCostTracker.configuration.reconciliation_importers[:anthropic]
      expect(importer.call).to eq(:registered)
    end

    it "raises when register_reconciliation_importer is called without a block" do
      expect do
        LlmCostTracker.configuration.register_reconciliation_importer(:anthropic)
      end.to raise_error(LlmCostTracker::Error, /requires a block/)
    end
  end

  describe "import lifecycle" do
    let(:rows) do
      [{
        external_id: "row-1",
        period_start: "2026-05-01",
        period_end: "2026-05-31",
        billed_amount: "1.00",
        metadata: envelope
      }]
    end

    it "opens a running import record and marks it completed on success" do
      result = LlmCostTracker::Reconciliation.import(
        source: :openai, rows: rows, cursor: "page-3",
        window: Date.new(2026, 5, 1)..Date.new(2026, 5, 31)
      )

      expect(result.import_id).not_to be_nil
      record = LlmCostTracker::ProviderInvoiceImport.find(result.import_id)
      expect(record).to have_attributes(
        source: "openai",
        state: LlmCostTracker::ProviderInvoiceImport::STATE_COMPLETED,
        cursor: "page-3",
        window_start: Date.new(2026, 5, 1),
        window_end: Date.new(2026, 5, 31),
        rows_imported: 1
      )
      expect(record.finished_at).not_to be_nil
    end

    it "marks the record failed when the import path raises" do
      allow(LlmCostTracker::ProviderInvoice).to receive(:upsert_all).and_raise("boom")

      expect do
        LlmCostTracker::Reconciliation.import(source: :openai, rows: rows)
      end.to raise_error(/boom/)

      record = LlmCostTracker::ProviderInvoiceImport.last
      expect(record.state).to eq(LlmCostTracker::ProviderInvoiceImport::STATE_FAILED)
      expect(record.last_error).to include("boom")
    end

    it "exposes the latest cursor through ProviderInvoiceImport.resume_cursor_for" do
      LlmCostTracker::Reconciliation.import(source: :openai, rows: rows, cursor: "page-1")
      LlmCostTracker::Reconciliation.import(source: :openai, rows: [], cursor: "page-2")

      expect(LlmCostTracker::ProviderInvoiceImport.resume_cursor_for("openai")).to eq("page-2")
    end

    it "still imports when the tracking table is absent" do
      ActiveRecord::Base.connection.drop_table(:llm_cost_tracker_provider_invoice_imports)
      LlmCostTracker::ProviderInvoiceImport.reset_column_information

      result = LlmCostTracker::Reconciliation.import(source: :openai, rows: rows)

      expect(result.inserted).to eq(1)
      expect(result.import_id).to be_nil
    end

    it "raises an installable error when reconciliation tables are missing" do
      ActiveRecord::Base.connection.drop_table(:llm_cost_tracker_provider_invoices, force: :cascade)
      LlmCostTracker::ProviderInvoice.reset_column_information

      expect do
        LlmCostTracker::Reconciliation.import(source: :openai, rows: rows)
      end.to raise_error(LlmCostTracker::Error, /llm_cost_tracker:reconciliation/)
    end

    it "stores nil billed_amount when the provider row has no charge value" do
      described_class.import(
        source: :openai,
        rows: [{
          external_id: "no-amount",
          period_start: "2026-05-01",
          period_end: "2026-05-31",
          billed_amount: nil,
          metadata: envelope
        }]
      )

      expect(LlmCostTracker::ProviderInvoice.find_by!(external_id: "openai:no-amount").billed_amount)
        .to be_nil
    end

    it "skips rows with unparseable dates and reports the error" do
      result = described_class.import(
        source: :openai,
        rows: [{
          external_id: "bad-date",
          period_start: "not-a-date",
          period_end: "2026-05-31"
        }]
      )

      expect(result.skipped).to eq(1)
      expect(result.errors.first).to include("row 0:")
      expect(result).not_to be_success
      expect(LlmCostTracker::ProviderInvoice.count).to eq(0)
    end
  end
end
