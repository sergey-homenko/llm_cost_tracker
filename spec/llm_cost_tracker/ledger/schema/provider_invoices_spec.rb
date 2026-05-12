# frozen_string_literal: true

require "spec_helper"

require_relative "../../../dummy/config/environment"
require "llm_cost_tracker/reconciliation"

RSpec.describe LlmCostTracker::Ledger::Schema::ProviderInvoices do
  include_context "with mounted llm cost tracker engine"
  include_context "with reconciliation enabled"

  describe ".current_schema_errors" do
    it "returns no errors for the install-generated schema" do
      expect(described_class.current_schema_errors).to eq([])
    end

    it "reports a missing table" do
      ActiveRecord::Base.connection.drop_table(:llm_cost_tracker_provider_invoices)
      LlmCostTracker::ProviderInvoice.reset_column_information

      expect(described_class.current_schema_errors)
        .to include("llm_cost_tracker_provider_invoices table is missing")
    end

    it "reports missing required columns" do
      ActiveRecord::Base.connection.remove_column(:llm_cost_tracker_provider_invoices, :external_id)
      LlmCostTracker::ProviderInvoice.reset_column_information

      expect(described_class.current_schema_errors)
        .to include("missing columns: external_id")
    end

    it "reports a missing unique index on external_id" do
      ActiveRecord::Base.connection.remove_index(:llm_cost_tracker_provider_invoices, :external_id)

      expect(described_class.current_schema_errors)
        .to include("missing unique index: external_id")
    end

    it "reports a missing source/currency/period_start index" do
      ActiveRecord::Base.connection.remove_index(
        :llm_cost_tracker_provider_invoices, %i[source currency period_start]
      )

      expect(described_class.current_schema_errors)
        .to include("missing index: source, currency, period_start")
    end

    it "rejects metadata columns of the wrong adapter type" do
      metadata_column = LlmCostTracker::ProviderInvoice.columns_hash["metadata"]
      double = instance_double(metadata_column.class, sql_type: "varchar(255)", type: :string)
      allow(LlmCostTracker::ProviderInvoice).to receive(:columns_hash)
        .and_return("metadata" => double)

      expect(described_class.current_schema_errors)
        .to include(match(/metadata column must use (jsonb|json) \(got varchar/))
    end
  end
end
