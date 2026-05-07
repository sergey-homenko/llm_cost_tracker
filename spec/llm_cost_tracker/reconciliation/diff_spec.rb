# frozen_string_literal: true

require "spec_helper"

require_relative "../../dummy/config/environment"

RSpec.describe LlmCostTracker::Reconciliation::Diff do
  include_context "with mounted llm cost tracker engine"

  let(:period_start) { Date.new(2026, 5, 1) }
  let(:period_end) { Date.new(2026, 5, 31) }

  def import_invoice(external_id:, billed_amount:, source: "openai", currency: "USD",
                     period_start: Date.new(2026, 5, 1), period_end: Date.new(2026, 5, 31), metadata: {})
    LlmCostTracker::Reconciliation.import(
      source: source,
      rows: [{
        external_id: external_id,
        period_start: period_start,
        period_end: period_end,
        billed_amount: billed_amount,
        currency: currency,
        metadata: metadata
      }]
    )
  end

  def create_priced_call(total_cost:, tracked_at: Time.utc(2026, 5, 15, 12), provider: "openai",
                         model: "gpt-4o", currency: "USD", **dimensions)
    call = LlmCostTracker::Call.create!(
      provider: provider,
      model: model,
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15,
      total_cost: total_cost,
      cost_status: LlmCostTracker::Billing::CostStatus::COMPLETE,
      tracked_at: tracked_at,
      **dimensions
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
      currency: currency,
      cost_status: LlmCostTracker::Billing::CostStatus::COMPLETE,
      pricing_basis: "rate_table",
      details: {}
    )
    call
  end

  describe "#call" do
    it "computes provider total, local total, and delta for the period" do
      import_invoice(external_id: "row-1", billed_amount: "100.00")
      create_priced_call(total_cost: BigDecimal("95.00"))

      result = LlmCostTracker::Reconciliation.diff(
        source: :openai, period_start: period_start, period_end: period_end
      )

      expect(result.provider_total).to eq(BigDecimal("100.00"))
      expect(result.local_total).to eq(BigDecimal("95.00"))
      expect(result.delta_amount).to eq(BigDecimal("-5.00"))
      expect(result.delta_percent).to eq(-5.0)
      expect(result).not_to be_aligned(threshold_percent: 1)
      expect(result).to be_aligned(threshold_percent: 10)
    end

    it "returns nil delta_percent when provider total is zero" do
      create_priced_call(total_cost: BigDecimal("3.00"))

      result = LlmCostTracker::Reconciliation.diff(
        source: :openai, period_start: period_start, period_end: period_end
      )

      expect(result.provider_total).to eq(BigDecimal("0"))
      expect(result.local_total).to eq(BigDecimal("3.00"))
      expect(result.delta_percent).to be_nil
      expect(result).not_to be_aligned
    end

    it "ignores invoices and calls outside the period window" do
      import_invoice(external_id: "current", billed_amount: "10.00")
      import_invoice(
        external_id: "previous-month",
        billed_amount: "999.00",
        period_start: Date.new(2026, 4, 1),
        period_end: Date.new(2026, 4, 30)
      )
      create_priced_call(total_cost: BigDecimal("9.50"))
      create_priced_call(total_cost: BigDecimal("888.00"), tracked_at: Time.utc(2026, 4, 15, 12))

      result = LlmCostTracker::Reconciliation.diff(
        source: :openai, period_start: period_start, period_end: period_end
      )

      expect(result.provider_total).to eq(BigDecimal("10.00"))
      expect(result.local_total).to eq(BigDecimal("9.50"))
    end

    it "filters by attribution scope on both sides" do
      import_invoice(
        external_id: "row-a",
        billed_amount: "50.00",
        metadata: { provider_project_id: "proj_a" }
      )
      import_invoice(
        external_id: "row-b",
        billed_amount: "30.00",
        metadata: { provider_project_id: "proj_b" }
      )
      create_priced_call(total_cost: BigDecimal("48.00"), provider_project_id: "proj_a")
      create_priced_call(total_cost: BigDecimal("29.00"), provider_project_id: "proj_b")

      result = LlmCostTracker::Reconciliation.diff(
        source: :openai,
        period_start: period_start,
        period_end: period_end,
        scope: { provider_project_id: "proj_a" }
      )

      expect(result.provider_total).to eq(BigDecimal("50.00"))
      expect(result.local_total).to eq(BigDecimal("48.00"))
      expect(result.scope).to eq(provider_project_id: "proj_a")
    end

    it "isolates the diff to the requested currency" do
      import_invoice(external_id: "usd", billed_amount: "10.00", currency: "USD")
      import_invoice(external_id: "eur", billed_amount: "9999.00", currency: "EUR")
      create_priced_call(total_cost: BigDecimal("9.50"))

      result = LlmCostTracker::Reconciliation.diff(
        source: :openai, period_start: period_start, period_end: period_end
      )

      expect(result.provider_total).to eq(BigDecimal("10.00"))
      expect(result.currency).to eq("USD")
    end

    it "ignores foreign-currency local line items when summing the local total" do
      import_invoice(external_id: "usd", billed_amount: "10.00", currency: "USD")
      create_priced_call(total_cost: BigDecimal("9.00"), currency: "USD")
      create_priced_call(total_cost: BigDecimal("888.00"), currency: "EUR")

      result = LlmCostTracker::Reconciliation.diff(
        source: :openai, period_start: period_start, period_end: period_end
      )

      expect(result.local_total).to eq(BigDecimal("9.00"))
    end

    it "matches a project-level invoice against calls that also carry a finer api_key dimension" do
      import_invoice(
        external_id: "project-coverage",
        billed_amount: "10.00",
        metadata: { match_basis: "project", provider_project_id: "proj_x" }
      )
      create_priced_call(
        total_cost: BigDecimal("10.00"),
        provider_project_id: "proj_x",
        provider_api_key_id: "key_specific"
      )

      result = LlmCostTracker::Reconciliation.diff(
        source: :openai, period_start: period_start, period_end: period_end
      )

      expect(result.unmatched_provider_rows).to be_empty
      expect(result.unmatched_local_calls).to be_empty
    end

    it "tags unmatched provider rows with the basis the matcher used" do
      import_invoice(
        external_id: "phantom",
        billed_amount: "5.00",
        metadata: { match_basis: "project", provider_project_id: "proj_phantom" }
      )

      result = LlmCostTracker::Reconciliation.diff(
        source: :openai, period_start: period_start, period_end: period_end
      )

      expect(result.unmatched_provider_rows.first[:match_basis]).to eq("project")
    end

    it "treats invoices declared as period-level as always matched" do
      import_invoice(
        external_id: "monthly-total",
        billed_amount: "10.00",
        metadata: { match_basis: "period_only" }
      )

      result = LlmCostTracker::Reconciliation.diff(
        source: :openai, period_start: period_start, period_end: period_end
      )

      expect(result.unmatched_provider_rows).to be_empty
    end

    it "is empty when no provider rows and no priced calls exist for the window" do
      result = LlmCostTracker::Reconciliation.diff(
        source: :openai, period_start: period_start, period_end: period_end
      )

      expect(result).to be_empty
      expect(result).to be_aligned
    end

    it "raises when period_end precedes period_start" do
      expect do
        LlmCostTracker::Reconciliation.diff(
          source: :openai,
          period_start: Date.new(2026, 5, 31),
          period_end: Date.new(2026, 5, 1)
        )
      end.to raise_error(ArgumentError, /period_end must be on or after/)
    end

    it "raises when source is blank" do
      expect do
        LlmCostTracker::Reconciliation.diff(
          source: "", period_start: period_start, period_end: period_end
        )
      end.to raise_error(ArgumentError, /source must be present/)
    end

    it "accepts ISO date strings for the period bounds" do
      import_invoice(external_id: "iso-strings", billed_amount: "1.00")
      create_priced_call(total_cost: BigDecimal("1.00"))

      result = LlmCostTracker::Reconciliation.diff(
        source: :openai, period_start: "2026-05-01", period_end: "2026-05-31"
      )

      expect(result.provider_total).to eq(BigDecimal("1.00"))
      expect(result.local_total).to eq(BigDecimal("1.00"))
    end

    it "lists provider rows whose attribution has no matching local call" do
      import_invoice(
        external_id: "phantom",
        billed_amount: "12.00",
        metadata: { provider_project_id: "proj_phantom" }
      )
      import_invoice(
        external_id: "matched",
        billed_amount: "8.00",
        metadata: { provider_project_id: "proj_known" }
      )
      create_priced_call(total_cost: BigDecimal("8.00"), provider_project_id: "proj_known")

      result = LlmCostTracker::Reconciliation.diff(
        source: :openai, period_start: period_start, period_end: period_end
      )

      expect(result.unmatched_provider_rows.size).to eq(1)
      expect(result.unmatched_provider_rows.first).to include(
        external_id: "openai:phantom",
        attribution: include(provider_project_id: "proj_phantom")
      )
    end

    it "lists local call attributions that no provider row could explain" do
      import_invoice(
        external_id: "matched",
        billed_amount: "8.00",
        metadata: { provider_project_id: "proj_known" }
      )
      create_priced_call(total_cost: BigDecimal("8.00"), provider_project_id: "proj_known")
      create_priced_call(total_cost: BigDecimal("3.00"), provider_project_id: "proj_orphan")
      create_priced_call(total_cost: BigDecimal("4.50"), provider_project_id: "proj_orphan")

      result = LlmCostTracker::Reconciliation.diff(
        source: :openai, period_start: period_start, period_end: period_end
      )

      expect(result.unmatched_local_calls.size).to eq(1)
      orphan = result.unmatched_local_calls.first
      expect(orphan[:attribution]).to include(provider_project_id: "proj_orphan")
      expect(orphan[:count]).to eq(2)
      expect(orphan[:total_cost]).to eq(BigDecimal("7.50"))
    end

    it "ignores invoices and calls with no attribution dimensions for unmatched lists" do
      import_invoice(external_id: "totals-only", billed_amount: "5.00", metadata: {})
      create_priced_call(total_cost: BigDecimal("5.00"))

      result = LlmCostTracker::Reconciliation.diff(
        source: :openai, period_start: period_start, period_end: period_end
      )

      expect(result.unmatched_provider_rows).to be_empty
      expect(result.unmatched_local_calls).to be_empty
    end

    it "filters local calls by the provider implied by source" do
      import_invoice(external_id: "openai-row", billed_amount: "10.00", source: "openai")
      create_priced_call(total_cost: BigDecimal("10.00"), provider: "openai")
      create_priced_call(total_cost: BigDecimal("99.00"), provider: "anthropic")

      result = LlmCostTracker::Reconciliation.diff(
        source: :openai, period_start: period_start, period_end: period_end
      )

      expect(result.local_total).to eq(BigDecimal("10.00"))
    end

    it "leaves local calls unfiltered when source has no documented provider mapping" do
      import_invoice(external_id: "csv-row", billed_amount: "20.00", source: "csv")
      create_priced_call(total_cost: BigDecimal("12.00"), provider: "openai")
      create_priced_call(total_cost: BigDecimal("8.00"), provider: "anthropic")

      result = LlmCostTracker::Reconciliation.diff(
        source: :csv, period_start: period_start, period_end: period_end
      )

      expect(result.local_total).to eq(BigDecimal("20.00"))
    end

    it "excludes free_quota and credit rows from the financial provider total" do
      import_invoice(
        external_id: "billed",
        billed_amount: "10.00",
        metadata: { row_type: "cost" }
      )
      import_invoice(
        external_id: "free-credit",
        billed_amount: "5.00",
        metadata: { row_type: "free_quota", meter: "tokens" }
      )
      import_invoice(
        external_id: "adjustment",
        billed_amount: "-1.00",
        metadata: { row_type: "credit", meter: "tokens" }
      )
      create_priced_call(total_cost: BigDecimal("10.00"))

      result = LlmCostTracker::Reconciliation.diff(
        source: :openai, period_start: period_start, period_end: period_end
      )

      expect(result.provider_total).to eq(BigDecimal("10.00"))
      expect(result.local_total).to eq(BigDecimal("10.00"))
      expect(result.non_cost_rows.size).to eq(2)
      expect(result.non_cost_rows.map { |row| row[:row_type] }).to contain_exactly("free_quota", "credit")
    end
  end
end
