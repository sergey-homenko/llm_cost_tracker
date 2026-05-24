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

    it "recomputes after a new migration bumps the schema version, without an explicit reset" do
      connection = ActiveRecord::Base.connection
      connection.create_table(:schema_migrations, id: false, if_not_exists: true) { |t| t.string :version, null: false, primary_key: true }
      connection.execute("INSERT INTO schema_migrations(version) VALUES('1')")
      described_class.current

      connection.remove_column(:llm_cost_tracker_calls, :pricing_mode)
      connection.execute("INSERT INTO schema_migrations(version) VALUES('2')")

      drift = described_class.current
      expect(drift.message).to include("llm_cost_tracker_calls table does not match")
    ensure
      connection.drop_table(:schema_migrations, if_exists: true)
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
      allow(LlmCostTracker::Ledger::Schema::IngestionInboxEntries)
        .to receive(:current_schema_errors)
        .and_return(["missing columns: payload"])

      drift = described_class.current

      expect(drift.message).to include("llm_cost_tracker_ingestion_inbox_entries")
      expect(drift.details).to include("missing columns: payload")
    end
  end
end
