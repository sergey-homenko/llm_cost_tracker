# frozen_string_literal: true

require "json"
require "spec_helper"
require "tempfile"

ENV["RAILS_ENV"] ||= "test"

require_relative "../dummy/config/environment"

RSpec.describe LlmCostTracker::Doctor do
  it "reports a missing ActiveRecord ledger setup" do
    establish_database_connection!

    checks = described_class.call

    expect(checks).to include(
      have_attributes(status: :ok, name: "configuration"),
      have_attributes(status: :ok, name: "capture", message: include("Faraday middleware and manual capture")),
      have_attributes(status: :ok, name: "active_record"),
      have_attributes(status: :error, name: "llm_cost_tracker_calls"),
      have_attributes(status: :warn, name: "prices")
    )
    expect(checks.find { |check| check.name == "prices" }.message).to include("commit a prices_file")
    expect(described_class.healthy?).to be false
  ensure
    disconnect_database!
  end

  it "warns when tracking is disabled" do
    LlmCostTracker.configure { |config| config.enabled = false }

    check = described_class.call.find { |item| item.name == "capture" }

    expect(check).to have_attributes(status: :warn, message: include("tracking is disabled"))
  end

  it "warns when the configured prices file is stale" do
    Tempfile.create(["llm-prices", ".json"]) do |file|
      file.write({
        metadata: { updated_at: "2026-01-01", currency: "USD", unit: "1M tokens" },
        models: { "custom-model" => { input: 1.0, output: 2.0 } }
      }.to_json)
      file.close

      LlmCostTracker.configure { |config| config.prices_file = file.path }

      check = described_class.call.find { |item| item.name == "prices" }

      expect(check.status).to eq(:warn)
      expect(check.message).to include("older than 30 days")
      expect(check.message).to include("llm_cost_tracker:prices:refresh")
    end
  end

  it "accepts a fresh configured prices file" do
    Tempfile.create(["llm-prices", ".json"]) do |file|
      file.write({
        metadata: { updated_at: Date.today.iso8601, currency: "USD", unit: "1M tokens" },
        models: { "custom-model" => { input: 1.0, output: 2.0 } }
      }.to_json)
      file.close

      LlmCostTracker.configure { |config| config.prices_file = file.path }

      check = described_class.call.find { |item| item.name == "prices" }

      expect(check.status).to eq(:ok)
      expect(check.message).to include("updated_at=#{Date.today.iso8601}")
    end
  end

  it "treats table probe errors as absent tables" do
    allow(LlmCostTracker::Call).to receive(:connection).and_raise("database unavailable")

    expect(described_class::Probe.table_exists?("llm_cost_tracker_calls")).to be false
  end

  it "skips isolated checks when the ledger table is missing" do
    allow(described_class::Probe).to receive(:table_exists?).with("llm_cost_tracker_calls").and_return(false)

    expect(described_class::IngestionCheck.new.call).to be_nil
    expect(described_class::LegacyAuditCheck.new.call).to be_nil
    expect(described_class::LegacyBillingStatusCheck.new.call).to be_nil
    expect(
      described_class::SchemaCheck.new(
        name: "call line items",
        schema: LlmCostTracker::Ledger::Schema::CallLineItems,
        table: "llm_cost_tracker_call_line_items"
      ).call
    ).to be_nil
  end

  context "with ActiveRecord storage" do
    include_context "with mounted llm cost tracker engine"

    it "reports table, column, call rollup, and call status" do
      checks = described_class.call

      expect(checks).to include(
        have_attributes(status: :ok, name: "llm_cost_tracker_calls"),
        have_attributes(status: :ok, name: "llm_cost_tracker_calls columns"),
        have_attributes(status: :ok, name: "call line items"),
        have_attributes(status: :ok, name: "call tags"),
        have_attributes(status: :ok, name: "provider invoices"),
        have_attributes(status: :ok, name: "call rollups"),
        have_attributes(status: :warn, name: "tracked calls")
      )
    end

    it "fails when provider invoices table is missing" do
      ActiveRecord::Base.connection.drop_table(:llm_cost_tracker_provider_invoices)
      LlmCostTracker::ProviderInvoice.reset_column_information

      check = described_class.call.find { |item| item.name == "provider invoices" }

      expect(check).to have_attributes(status: :error)
      expect(check.message).to include("llm_cost_tracker_provider_invoices table is missing")
      expect(check.message).to include("llm_cost_tracker:install")
    end

    it "fails when call rollups are missing" do
      ActiveRecord::Base.connection.drop_table(:llm_cost_tracker_call_rollups)

      check = described_class.call.find { |item| item.name == "call rollups" }

      expect(check).to have_attributes(status: :error)
      expect(check.message).to include("schema mismatch")
      expect(check.message).to include("llm_cost_tracker_call_rollups table is missing")
      expect(check.message).to include("docs/upgrading.md")
    end

    it "fails when durable ingestion tables are missing" do
      ActiveRecord::Base.connection.drop_table(:llm_cost_tracker_ingestion_inbox_entries)
      ActiveRecord::Base.connection.drop_table(:llm_cost_tracker_ingestion_leases)

      check = described_class.call.find { |item| item.name == "durable ingestion" }

      expect(check).to have_attributes(status: :error)
      expect(check.message).to include("llm_cost_tracker_ingestion_inbox_entries")
      expect(check.message).to include("llm_cost_tracker_ingestion_leases")
      expect(check.message).to include("docs/upgrading.md")
    end

    it "fails when call rollups lack the current unique index" do
      ActiveRecord::Base.connection.remove_index(
        :llm_cost_tracker_call_rollups, %i[period period_start currency provider]
      )

      check = described_class.call.find { |item| item.name == "call rollups" }

      expect(check).to have_attributes(status: :error)
      expect(check.message).to include("missing unique index: period, period_start, currency, provider")
      expect(check.message).to include("docs/upgrading.md")
    end

    it "fails when the ledger table does not match the current schema" do
      ActiveRecord::Base.connection.remove_column(:llm_cost_tracker_calls, :pricing_mode)
      LlmCostTracker::Call.reset_column_information

      check = described_class.call.find { |item| item.name == "llm_cost_tracker_calls columns" }

      expect(check.status).to eq(:error)
      expect(check.message).to include("schema mismatch")
      expect(check.message).to include("missing columns: pricing_mode")
      expect(check.message).to include("docs/upgrading.md")
    end

    it "fails when call line items are missing" do
      ActiveRecord::Base.connection.drop_table(:llm_cost_tracker_call_line_items)
      LlmCostTracker::CallLineItem.reset_column_information

      check = described_class.call.find { |item| item.name == "call line items" }

      expect(check).to have_attributes(status: :error)
      expect(check.message).to include("llm_cost_tracker_call_line_items table is missing")
      expect(check.message).to include("llm_cost_tracker:install")
    end

    it "fails when call tags are missing" do
      ActiveRecord::Base.connection.drop_table(:llm_cost_tracker_call_tags)
      LlmCostTracker::CallTag.reset_column_information

      check = described_class.call.find { |item| item.name == "call tags" }

      expect(check).to have_attributes(status: :error)
      expect(check.message).to include("llm_cost_tracker_call_tags table is missing")
      expect(check.message).to include("llm_cost_tracker:install")
    end

    it "reports recorded calls" do
      create_call(model: "gpt-4o")

      check = described_class.call.find { |item| item.name == "tracked calls" }

      expect(check.status).to eq(:ok)
      expect(check.message).to include("1 recorded")
    end

    it "warns when legacy rows without cost status remain" do
      ActiveRecord::Base.connection.change_column_null(:llm_cost_tracker_calls, :cost_status, true)
      LlmCostTracker::Call.reset_column_information
      create_call(model: "legacy-status", cost_status: nil)

      check = described_class.call.find { |item| item.name == "cost status" }

      expect(check).to have_attributes(status: :warn)
      expect(check.message).to include("legacy rows without cost_status remain")
    end

    it "skips legacy checks when schema lookup fails" do
      allow(LlmCostTracker::Call).to receive(:column_names).and_raise("schema unavailable")

      expect(described_class::LegacyAuditCheck.new.call).to be_nil
      expect(described_class::LegacyBillingStatusCheck.new.call).to be_nil
    end

    it "skips legacy checks before billing audit columns exist" do
      allow(LlmCostTracker::Call).to receive(:column_names).and_return([])

      expect(described_class::LegacyAuditCheck.new.call).to be_nil
      expect(described_class::LegacyBillingStatusCheck.new.call).to be_nil
    end

    it "warns when legacy rows without pricing snapshots exceed the audit threshold" do
      2.times { |index| create_call(model: "legacy-#{index}", pricing_snapshot: nil) }
      9.times { |index| create_call(model: "current-#{index}") }

      check = described_class.call.find { |item| item.name == "pricing snapshot audit" }

      expect(check).to have_attributes(status: :warn)
      expect(check.message).to include("2/11 tracked calls")
    end

    it "does not warn when pricing snapshot legacy rows stay at the audit threshold" do
      create_call(model: "legacy-snapshot", pricing_snapshot: nil)
      9.times { |index| create_call(model: "current-#{index}") }

      check = described_class.call.find { |item| item.name == "pricing snapshot audit" }

      expect(check).to be_nil
    end
  end
end
