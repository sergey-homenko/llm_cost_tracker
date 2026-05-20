# frozen_string_literal: true

require "spec_helper"

ENV["RAILS_ENV"] ||= "test"

require_relative "../../dummy/config/environment"

RSpec.describe "LlmCostTracker::Engine reconciliation" do
  include_context "with mounted llm cost tracker engine"
  include_context "with reconciliation enabled"

  ENVELOPE = { row_type: "cost", meter: "tokens", authority: "cost_api", match_basis: "period_only" }.freeze

  def import_invoice(billed_amount:, source: :openai, external_id: "row", metadata: ENVELOPE)
    LlmCostTracker::Reconciliation.import(
      source: source,
      rows: [{
        external_id: external_id,
        period_start: Date.new(2026, 5, 1),
        period_end: Date.new(2026, 5, 31),
        billed_amount: billed_amount,
        currency: "USD",
        metadata: metadata
      }]
    )
  end

  def create_priced_call(total_cost:, **dimensions)
    call = create_call(total_cost: total_cost, tracked_at: Time.utc(2026, 5, 15, 12), **dimensions)
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
  end

  it "renders the disabled state when reconciliation has not been enabled" do
    LlmCostTracker.reset_configuration!

    response = get("/llm-costs/reconciliation")

    expect(response.status).to eq(200)
    expect(response.body).to include("Reconciliation disabled")
    expect(response.body).to include("config.reconciliation_enabled = true")
  end

  it "rejects trigger_import when reconciliation is disabled" do
    LlmCostTracker.reset_configuration!

    response = post("/llm-costs/reconciliation/import", params: { source: "openai" })

    expect(response.status).to eq(302)
  end

  it "renders the install hint when reconciliation tables are absent" do
    ActiveRecord::Base.connection.drop_table(:llm_cost_tracker_provider_invoices, force: :cascade)
    LlmCostTracker::ProviderInvoice.reset_column_information

    response = get("/llm-costs/reconciliation")

    expect(response.status).to eq(200)
    expect(response.body).to include("llm_cost_tracker_provider_invoices table is required")
    expect(response.body).to include("llm_cost_tracker:reconciliation")
  end

  it "renders the setup-required page when an optional table drifts from the current schema" do
    ActiveRecord::Base.connection.remove_column(:llm_cost_tracker_provider_invoices, :external_id)
    LlmCostTracker::ProviderInvoice.reset_column_information

    response = get("/llm-costs/reconciliation")

    expect(response.body).to include("does not match the current LLM Cost Tracker schema")
  end

  it "renders an empty state when no invoices have been imported" do
    response = get("/llm-costs/reconciliation")

    expect(response.status).to eq(200)
    expect(response.body).to include("No invoices imported yet")
  end

  it "shows aligned status for sources within the threshold" do
    import_invoice(billed_amount: BigDecimal("100.00"))
    create_priced_call(total_cost: BigDecimal("99.00"))

    response = get("/llm-costs/reconciliation")

    expect(response.status).to eq(200)
    expect(response.body).to include("openai")
    expect(response.body).to include("Aligned")
  end

  it "shows drift status when local total diverges past the threshold" do
    import_invoice(billed_amount: BigDecimal("100.00"))
    create_priced_call(total_cost: BigDecimal("75.00"))

    response = get("/llm-costs/reconciliation")

    expect(response.status).to eq(200)
    expect(response.body).to include("Drift")
  end

  it "surfaces unmatched provider rows with their attribution" do
    import_invoice(
      billed_amount: BigDecimal("12.00"),
      external_id: "phantom",
      metadata: { match_basis: "project", row_type: "cost", meter: "tokens",
                  authority: "cost_api", provider_project_id: "proj_phantom" }
    )

    response = get("/llm-costs/reconciliation")

    expect(response.body).to include("Provider rows without a matching local call")
    expect(response.body).to include("openai:phantom")
    expect(response.body).to include("provider_project_id=***ntom")
  end

  it "renders the dashboard without crashing when a legacy invoice cannot resolve to a provider" do
    allow(LlmCostTracker::Logging).to receive(:warn)
    LlmCostTracker::ProviderInvoice.create!(
      source: "legacy_csv",
      external_id: "legacy_csv:row",
      period_start: Date.new(2026, 5, 1),
      period_end: Date.new(2026, 5, 31),
      billed_amount: BigDecimal("5.00"),
      currency: "USD",
      metadata: {},
      imported_at: Time.now.utc
    )

    response = get("/llm-costs/reconciliation")

    expect(response.status).to eq(200)
    expect(LlmCostTracker::Logging).to have_received(:warn).with(/legacy_csv.*provider/)
  end

  it "exposes a re-import button when an importer is configured for the source" do
    LlmCostTracker.configuration.reconciliation_importers = {
      openai: -> { LlmCostTracker::Reconciliation::ImportResult.empty }
    }
    import_invoice(billed_amount: BigDecimal("1.00"))

    response = get("/llm-costs/reconciliation")

    expect(response.body).to include("Re-import openai")
  ensure
    LlmCostTracker.configuration.reconciliation_importers = {}
  end

  it "runs the configured importer when the trigger button is posted" do
    invoked = 0
    LlmCostTracker.configuration.reconciliation_importers = {
      openai: lambda do
        invoked += 1
        LlmCostTracker::Reconciliation::ImportResult.new(
          inserted: 3, updated: 0, skipped: 0, errors: []
        )
      end
    }

    response = post("/llm-costs/reconciliation/import", params: { source: "openai" })

    expect(response.status).to eq(302)
    expect(response.headers["Location"]).to end_with("/llm-costs/reconciliation")
    expect(invoked).to eq(1)
  ensure
    LlmCostTracker.configuration.reconciliation_importers = {}
  end

  it "redirects when no importer is registered for the requested source" do
    response = post("/llm-costs/reconciliation/import", params: { source: "anthropic" })

    expect(response.status).to eq(302)
    expect(response.headers["Location"]).to end_with("/llm-costs/reconciliation")
  end

  it "redirects with the alert when the configured importer raises" do
    LlmCostTracker.configuration.reconciliation_importers = {
      openai: -> { raise "boom" }
    }

    response = post("/llm-costs/reconciliation/import", params: { source: "openai" })

    expect(response.status).to eq(302)
  ensure
    LlmCostTracker.configuration.reconciliation_importers = {}
  end

  it "redirects with the alert when the registered importer returns a non-ImportResult value" do
    allow(LlmCostTracker::Logging).to receive(:warn)
    LlmCostTracker.configuration.reconciliation_importers = { openai: -> { :ok } }

    response = post("/llm-costs/reconciliation/import", params: { source: "openai" })

    expect(response.status).to eq(302)
    expect(LlmCostTracker::Logging).to have_received(:warn).with(/Reconciliation import failed for openai/)
  ensure
    LlmCostTracker.configuration.reconciliation_importers = {}
  end

  it "masks api_key and workspace ids in the rendered attribution" do
    import_invoice(
      billed_amount: BigDecimal("12.00"),
      external_id: "with-secrets",
      metadata: { match_basis: "api_key", row_type: "cost", meter: "tokens",
                  authority: "cost_api",
                  provider_api_key_id: "sk-live-1234567890ABCDEF",
                  provider_workspace_id: "wrkspc_secret_id_abcdef" }
    )

    response = get("/llm-costs/reconciliation")

    expect(response.body).to include("provider_api_key_id=***CDEF")
    expect(response.body).not_to include("sk-live-1234567890ABCDEF")
    expect(response.body).not_to include("wrkspc_secret_id_abcdef")
  end

  it "surfaces non-cost evidence rows (free quota, credits)" do
    import_invoice(
      billed_amount: BigDecimal("5.00"),
      external_id: "free-quota",
      metadata: { row_type: "free_quota", meter: "tokens",
                  authority: "cost_api", match_basis: "period_only" }
    )

    response = get("/llm-costs/reconciliation")

    expect(response.body).to include("Non-cost evidence")
    expect(response.body).to include("free_quota")
  end
end
