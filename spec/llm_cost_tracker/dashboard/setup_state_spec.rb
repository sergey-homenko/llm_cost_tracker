# frozen_string_literal: true

require "spec_helper"

require_relative "../../dummy/config/environment"

RSpec.describe LlmCostTracker::Dashboard::SetupState do
  include_context "with mounted llm cost tracker engine"

  describe ".current" do
    it "returns nil when every required table matches the current schema" do
      expect(described_class.current).to be_nil
    end

    it "memoizes the schema check while the schema version is unchanged so dashboard requests don't re-query metadata" do
      described_class.current

      expect(LlmCostTracker::Ledger::Schema::Calls).not_to receive(:current_schema_errors)
      expect(LlmCostTracker::Ledger::Schema::CallLineItems).not_to receive(:current_schema_errors)
      expect(LlmCostTracker::Ledger::Schema::CallTags).not_to receive(:current_schema_errors)
      expect(LlmCostTracker::Ledger::Schema::CallRollups).not_to receive(:current_schema_errors)
      described_class.current
    end

    it "reports the calls table being missing" do
      described_class.reset!
      ActiveRecord::Base.connection.drop_table(:llm_cost_tracker_calls, force: :cascade)
      LlmCostTracker::Call.reset_column_information

      drift = described_class.current

      expect(drift.message).to include("not available yet")
    end

    it "reports drift on async ingestion tables when ingestion is async" do
      described_class.reset!
      allow(LlmCostTracker::Ingestion).to receive(:async?).and_return(true)
      allow(LlmCostTracker::Ledger::Schema::Ingestion::InboxEntries)
        .to receive(:current_schema_errors)
        .and_return(["missing columns: payload"])

      drift = described_class.current

      expect(drift.message).to include("llm_cost_tracker_ingestion_inbox_entries")
      expect(drift.details).to include("missing columns: payload")
    end
  end
end
