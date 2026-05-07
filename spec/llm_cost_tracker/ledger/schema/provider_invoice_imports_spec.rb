# frozen_string_literal: true

require "spec_helper"

require_relative "../../../dummy/config/environment"

RSpec.describe LlmCostTracker::Ledger::Schema::ProviderInvoiceImports do
  include_context "with mounted llm cost tracker engine"

  describe ".current_schema_errors" do
    it "returns no errors for the install-generated schema" do
      expect(described_class.current_schema_errors).to eq([])
    end

    it "reports a missing table" do
      ActiveRecord::Base.connection.drop_table(:llm_cost_tracker_provider_invoice_imports)
      LlmCostTracker::ProviderInvoiceImport.reset_column_information

      expect(described_class.current_schema_errors)
        .to include("llm_cost_tracker_provider_invoice_imports table is missing")
    end

    it "reports missing required columns" do
      ActiveRecord::Base.connection.remove_column(:llm_cost_tracker_provider_invoice_imports, :cursor)
      LlmCostTracker::ProviderInvoiceImport.reset_column_information

      expect(described_class.current_schema_errors)
        .to include("missing columns: cursor")
    end

    it "reports a missing source/started_at index" do
      ActiveRecord::Base.connection.remove_index(
        :llm_cost_tracker_provider_invoice_imports, %i[source started_at]
      )

      expect(described_class.current_schema_errors)
        .to include("missing index: source, started_at")
    end
  end
end
