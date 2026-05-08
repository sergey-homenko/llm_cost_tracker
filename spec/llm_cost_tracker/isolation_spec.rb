# frozen_string_literal: true

require "spec_helper"
require "tempfile"
require "open3"
require "json"

RSpec.describe "Reconciliation isolation contract" do
  let(:setup_code) do
    <<~RUBY
      require "bundler/setup"
      require "rails"
      require "active_record"
      require "active_support/core_ext"
      require "json"
      require "llm_cost_tracker"
    RUBY
  end

  def run_isolation_probe(probe_code)
    Tempfile.create(["isolation_probe", ".rb"]) do |file|
      file.write(setup_code + probe_code)
      file.flush
      output, status = Open3.capture2e("ruby", file.path)
      raise "isolation probe failed (#{status}):\n#{output}" unless status.success?

      output
    end
  end

  it "leaves Reconciliation autoload pending after a fresh require" do
    output = run_isolation_probe(<<~PROBE)
      puts JSON.generate(
        reconciliation: LlmCostTracker.autoload?(:Reconciliation),
        reconcile_tasks: LlmCostTracker.autoload?(:ReconcileTasks),
        invoice_check: LlmCostTracker::Doctor.autoload?(:InvoiceReconciliationCheck),
        provider_invoices_schema_defined: defined?(LlmCostTracker::Ledger::Schema::ProviderInvoices)
      )
    PROBE

    parsed = JSON.parse(output)
    expect(parsed["reconciliation"]).to eq("llm_cost_tracker/reconciliation")
    expect(parsed["reconcile_tasks"]).to eq("llm_cost_tracker/reconcile_tasks")
    expect(parsed["invoice_check"]).to eq("llm_cost_tracker/doctor/invoice_reconciliation_check")
    expect(parsed["provider_invoices_schema_defined"]).to be_nil
  end

  it "does not trigger Reconciliation autoload from LlmCostTracker.reconciliation_enabled?" do
    output = run_isolation_probe(<<~PROBE)
      LlmCostTracker.reconciliation_enabled?
      puts JSON.generate(autoload: LlmCostTracker.autoload?(:Reconciliation))
    PROBE

    expect(JSON.parse(output)["autoload"]).to eq("llm_cost_tracker/reconciliation")
  end

  it "does not trigger Reconciliation autoload from Doctor reconciliation hooks when disabled" do
    output = run_isolation_probe(<<~PROBE)
      doctor = LlmCostTracker::Doctor.new
      doctor.send(:reconciliation_invoice_check)
      doctor.send(:reconciliation_schema_checks)
      puts JSON.generate(autoload: LlmCostTracker.autoload?(:Reconciliation))
    PROBE

    expect(JSON.parse(output)["autoload"]).to eq("llm_cost_tracker/reconciliation")
  end

  it "loads Reconciliation namespace and ledger schemas when the constant is explicitly accessed" do
    output = run_isolation_probe(<<~PROBE)
      LlmCostTracker.const_get(:Reconciliation)
      puts JSON.generate(
        autoload: LlmCostTracker.autoload?(:Reconciliation),
        masking: defined?(LlmCostTracker::Reconciliation::Masking),
        provider_invoices_schema: defined?(LlmCostTracker::Ledger::Schema::ProviderInvoices)
      )
    PROBE

    parsed = JSON.parse(output)
    expect(parsed["autoload"]).to be_nil
    expect(parsed["masking"]).to eq("constant")
    expect(parsed["provider_invoices_schema"]).to eq("constant")
  end
end
