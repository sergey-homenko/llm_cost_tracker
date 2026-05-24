# frozen_string_literal: true

require "spec_helper"

require_relative "../../dummy/config/environment"

RSpec.describe LlmCostTracker::Doctor::InvoiceReconciliationCheck do
  include_context "with mounted llm cost tracker engine"
  include_context "with reconciliation enabled"

  let(:period_start) { Date.new(2026, 5, 1) }
  let(:period_end) { Date.new(2026, 5, 31) }

  def import_invoice(billed_amount:, external_id: "row", period_start: Date.new(2026, 5, 1),
                     period_end: Date.new(2026, 5, 31))
    LlmCostTracker::Reconciliation.import(
      source: :openai,
      rows: [{
        external_id: external_id,
        period_start: period_start,
        period_end: period_end,
        billed_amount: billed_amount,
        currency: "USD",
        metadata: {
          row_type: "cost",
          meter: "tokens",
          authority: "cost_api",
          match_basis: "period_only"
        }
      }]
    )
  end

  def create_priced_call(total_cost:, provider: "openai")
    tracked_at = Time.utc(2026, 5, 15, 12)
    call = LlmCostTracker::Call.create!(
      provider: provider,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15,
      total_cost: total_cost,
      cost_status: LlmCostTracker::Billing::CostStatus::COMPLETE,
      tracked_at: tracked_at
    )
    LlmCostTracker::CallLineItem.create!(
      llm_cost_tracker_call_id: call.id,
      position: 0,
      kind: "text_token",
      direction: "input",
      modality: "text",
      cache_state: "none",
      unit: "token",
      quantity: 10,
      rate_amount: BigDecimal("1.0"),
      rate_quantity: BigDecimal("1000000"),
      cost: total_cost,
      currency: "USD",
      cost_status: LlmCostTracker::Billing::CostStatus::COMPLETE,
      pricing_basis: "rate_table",
      details: {}
    )
    LlmCostTracker::Ledger::Rollups.increment!([
      Struct.new(:provider, :total_cost, :tracked_at, :pricing_snapshot)
            .new("openai", total_cost, tracked_at, { "currency" => "USD" })
    ])
  end

  describe "#call" do
    it "is skipped when the provider_invoices table is missing" do
      allow(LlmCostTracker::Doctor::Probe).to receive(:table_exists?).and_call_original
      allow(LlmCostTracker::Doctor::Probe).to receive(:table_exists?)
        .with("llm_cost_tracker_provider_invoices").and_return(false)

      expect(described_class.new.call).to be_nil
    end

    it "stays silent when no invoices have been imported yet so doctor doesn't nag uninstalled add-ons" do
      expect(described_class.new.call).to be_nil
    end

    it "reports ok per source when local cost matches the latest provider invoice within threshold" do
      travel_to_today(period_end + 1)
      import_invoice(billed_amount: BigDecimal("100.00"))
      create_priced_call(total_cost: BigDecimal("99.00"))

      checks = Array(described_class.new.call)

      expect(checks.first).to have_attributes(status: :ok, name: "invoice reconciliation: openai/openai/USD")
      expect(checks.first.message).to include("aligned")
    end

    it "warns per source when delta exceeds the configured threshold" do
      travel_to_today(period_end + 1)
      import_invoice(billed_amount: BigDecimal("100.00"))
      create_priced_call(total_cost: BigDecimal("75.00"))

      checks = Array(described_class.new.call)

      expect(checks.first).to have_attributes(status: :warn, name: "invoice reconciliation: openai/openai/USD")
      expect(checks.first.message).to include("drift")
      expect(checks.first.message).to include("exceeds")
    end

    it "warns per source when the latest invoice is older than the freshness threshold" do
      travel_to_today(period_end + 30)
      import_invoice(billed_amount: BigDecimal("10.00"))

      checks = Array(described_class.new.call)

      expect(checks.first).to have_attributes(status: :warn, name: "invoice reconciliation: openai/openai/USD")
      expect(checks.first.message).to include("no invoice imported")
    end

    it "evaluates each source independently so a stale provider does not hide behind a fresh one" do
      travel_to_today(period_end + 5)
      import_invoice(billed_amount: BigDecimal("10.00"))
      LlmCostTracker::Reconciliation.import(
        source: :anthropic,
        rows: [{
          external_id: "anth",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 1, 31),
          billed_amount: "5.00",
          currency: "USD",
          metadata: {
            row_type: "cost", meter: "tokens", authority: "cost_api", match_basis: "period_only"
          }
        }]
      )

      checks = Array(described_class.new.call)

      expect(checks.map(&:name)).to contain_exactly(
        "invoice reconciliation: anthropic/anthropic/USD", "invoice reconciliation: openai/openai/USD"
      )
      anthropic = checks.find { |c| c.name == "invoice reconciliation: anthropic/anthropic/USD" }
      expect(anthropic.status).to eq(:warn)
      expect(anthropic.message).to include("no invoice imported")
    end

    it "isolates a per-source ArgumentError to a per-source warn instead of failing the whole check" do
      travel_to_today(period_end + 1)
      import_invoice(billed_amount: BigDecimal("10.00"))
      LlmCostTracker::ProviderInvoice.create!(
        source: "legacy_csv",
        external_id: "legacy_csv:row",
        period_start: period_start,
        period_end: period_end,
        billed_amount: BigDecimal("5.00"),
        currency: "USD",
        metadata: {},
        imported_at: Time.now.utc
      )

      checks = Array(described_class.new.call)

      legacy = checks.find { |c| c.name.start_with?("invoice reconciliation: legacy_csv") }
      expect(legacy.status).to eq(:warn)
      expect(legacy.message).to include("provider")
      openai = checks.find { |c| c.name == "invoice reconciliation: openai/openai/USD" }
      expect(openai.status).to be_in(%i[ok warn])
    end

    it "separates checks by source / provider / currency so a CSV import that carries two providers under the same source surfaces drift on each independently" do
      travel_to_today(period_end + 1)
      LlmCostTracker::Reconciliation.import(
        source: :csv, provider: "openai",
        rows: [{
          external_id: "csv-openai", period_start: period_start, period_end: period_end,
          billed_amount: "20.00", currency: "USD",
          metadata: { row_type: "cost", meter: "tokens", authority: "manual", match_basis: "period_only" }
        }]
      )
      LlmCostTracker::Reconciliation.import(
        source: :csv, provider: "anthropic",
        rows: [{
          external_id: "csv-anthropic", period_start: period_start, period_end: period_end,
          billed_amount: "10.00", currency: "USD",
          metadata: { row_type: "cost", meter: "tokens", authority: "manual", match_basis: "period_only" }
        }]
      )
      create_priced_call(total_cost: BigDecimal("19.50"), provider: "openai")
      create_priced_call(total_cost: BigDecimal("9.75"), provider: "anthropic")

      checks = Array(described_class.new.call)
      names = checks.map(&:name)

      expect(names).to include(
        "invoice reconciliation: csv/openai/USD",
        "invoice reconciliation: csv/anthropic/USD"
      )
    end

    it "upcases legacy lowercase currency rows when grouping scopes so a rolling-preview install with 'usd' rows reaches Reconciliation.diff with 'USD'" do
      travel_to_today(period_end + 1)
      import_invoice(billed_amount: BigDecimal("10.00"))
      LlmCostTracker::ProviderInvoice.where(source: "openai").update_all(currency: "usd")

      scopes = LlmCostTracker::Reconciliation.invoice_scopes

      expect(scopes.map { |s| s[:currency] }).to all(eq("USD"))
    end

    it "surfaces a warn check when provider invoice rows are stored with non-uppercase currency, pointing at the backfill SQL — without this the dashboard silently zeroes for legacy lowercase data" do
      travel_to_today(period_end + 1)
      import_invoice(billed_amount: BigDecimal("10.00"))
      LlmCostTracker::ProviderInvoice.where(source: "openai").update_all(currency: "usd")

      checks = Array(described_class.new.call)
      canonicalisation = checks.find { |c| c.name == "invoice reconciliation: currency canonicalisation" }

      expect(canonicalisation).not_to be_nil
      expect(canonicalisation.status).to eq(:warn)
      expect(canonicalisation.message).to include("UPDATE llm_cost_tracker_provider_invoices SET currency = UPPER(currency)")
    end

    it "surfaces unexpected errors as :error status" do
      allow(LlmCostTracker::ProviderInvoice).to receive(:none?).and_raise("boom")

      check = described_class.new.call

      expect(check).to have_attributes(status: :error, message: include("boom"))
    end
  end

  def travel_to_today(date)
    allow(Time).to receive(:now).and_return(date.to_time.utc + 12.hours)
  end
end
