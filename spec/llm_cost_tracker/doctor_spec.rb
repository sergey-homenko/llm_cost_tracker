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
      have_attributes(status: :error, name: "llm_api_calls"),
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

  it "maps token usage and cost columns to the token usage generator" do
    columns = LlmCostTracker::Generators::AddTokenUsageGenerator::COLUMN_NAMES

    expect(columns.map { |column| described_class::COLUMN_GENERATORS.fetch(column) }.uniq).to eq(
      ["bin/rails generate llm_cost_tracker:add_token_usage"]
    )
  end

  it "maps billing audit columns to the billing generator" do
    columns = LlmCostTracker::Generators::AddBillingGenerator::COLUMN_NAMES

    expect(columns.map { |column| described_class::COLUMN_GENERATORS.fetch(column) }.uniq).to eq(
      ["bin/rails generate llm_cost_tracker:add_billing"]
    )
  end

  it "treats table probe errors as absent tables" do
    allow(LlmCostTracker::Ledger::Call).to receive(:connection).and_raise("database unavailable")

    expect(described_class::Probe.table_exists?("llm_api_calls")).to be false
  end

  it "skips isolated checks when the ledger table is missing" do
    allow(described_class::Probe).to receive(:table_exists?).with("llm_api_calls").and_return(false)

    expect(described_class::IngestionCheck.new.call).to be_nil
    expect(described_class::LegacyAuditCheck.new.call).to be_nil
    expect(described_class::LegacyBillingStatusCheck.new.call).to be_nil
    expect(described_class::ServiceChargesCheck.new.call).to be_nil
  end

  context "with ActiveRecord storage" do
    include_context "with mounted llm cost tracker engine"

    it "reports table, column, period total, and call status" do
      checks = described_class.call

      expect(checks).to include(
        have_attributes(status: :ok, name: "llm_api_calls"),
        have_attributes(status: :ok, name: "llm_api_calls columns"),
        have_attributes(status: :ok, name: "service charges"),
        have_attributes(status: :ok, name: "period totals"),
        have_attributes(status: :warn, name: "tracked calls")
      )
    end

    it "fails when period totals are missing" do
      ActiveRecord::Base.connection.drop_table(:llm_cost_tracker_period_totals)

      check = described_class.call.find { |item| item.name == "period totals" }

      expect(check).to have_attributes(status: :error)
      expect(check.message).to include("current schema required")
      expect(check.message).to include("llm_cost_tracker_period_totals table is missing")
      expect(check.message).to include("llm_cost_tracker:add_period_totals")
    end

    it "fails when durable ingestion tables are missing" do
      ActiveRecord::Base.connection.drop_table(:llm_cost_tracker_inbox_events)
      ActiveRecord::Base.connection.drop_table(:llm_cost_tracker_ingestor_leases)

      check = described_class.call.find { |item| item.name == "durable ingestion" }

      expect(check).to have_attributes(status: :error)
      expect(check.message).to include("llm_cost_tracker_inbox_events")
      expect(check.message).to include("llm_cost_tracker_ingestor_leases")
      expect(check.message).to include("llm_cost_tracker:add_ingestion")
    end

    it "fails when period totals lack the current unique index" do
      ActiveRecord::Base.connection.remove_index(:llm_cost_tracker_period_totals, %i[period period_start])

      check = described_class.call.find { |item| item.name == "period totals" }

      expect(check).to have_attributes(status: :error)
      expect(check.message).to include("missing unique index: period, period_start")
      expect(check.message).to include("llm_cost_tracker:add_period_totals")
    end

    it "fails when the ledger table does not match the current schema" do
      ActiveRecord::Base.connection.remove_column(:llm_api_calls, :pricing_mode)
      LlmCostTracker::Ledger::Call.reset_column_information

      check = described_class.call.find { |item| item.name == "llm_api_calls columns" }

      expect(check.status).to eq(:error)
      expect(check.message).to include("current schema required")
      expect(check.message).to include("missing columns: pricing_mode")
      expect(check.message).to include("bin/rails generate llm_cost_tracker:add_token_usage")
      expect(check.message).to include("bin/rails db:migrate")
    end

    it "fails when service charges are missing" do
      ActiveRecord::Base.connection.drop_table(:llm_cost_tracker_service_charges)
      LlmCostTracker::Ledger::ServiceCharge.reset_column_information

      check = described_class.call.find { |item| item.name == "service charges" }

      expect(check).to have_attributes(status: :error)
      expect(check.message).to include("llm_cost_tracker_service_charges table is missing")
      expect(check.message).to include("llm_cost_tracker:add_billing")
    end

    it "reports recorded calls" do
      create_call(model: "gpt-4o")

      check = described_class.call.find { |item| item.name == "tracked calls" }

      expect(check.status).to eq(:ok)
      expect(check.message).to include("1 recorded")
    end

    it "warns when legacy rows without cost status remain" do
      create_call(model: "legacy-status", cost_status: nil)

      check = described_class.call.find { |item| item.name == "billing status" }

      expect(check).to have_attributes(status: :warn)
      expect(check.message).to include("legacy rows without cost_status remain")
    end

    it "skips legacy checks when schema lookup fails" do
      allow(LlmCostTracker::Ledger::Call).to receive(:column_names).and_raise("schema unavailable")

      expect(described_class::LegacyAuditCheck.new.call).to be_nil
      expect(described_class::LegacyBillingStatusCheck.new.call).to be_nil
    end

    it "skips legacy checks before billing audit columns exist" do
      allow(LlmCostTracker::Ledger::Call).to receive(:column_names).and_return([])

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
