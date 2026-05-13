# frozen_string_literal: true

require "spec_helper"

require_relative "../../dummy/config/environment"

RSpec.describe LlmCostTracker::Dashboard::SetupState do
  include_context "with mounted llm cost tracker engine"

  describe ".current" do
    it "returns nil when every required table matches the current schema" do
      expect(described_class.current).to be_nil
    end

    it "memoizes the schema check across repeat calls so dashboard requests don't re-query metadata" do
      described_class.current

      expect(LlmCostTracker::Ledger::Schema::Calls).not_to receive(:current_schema_errors)
      expect(LlmCostTracker::Ledger::Schema::CallLineItems).not_to receive(:current_schema_errors)
      expect(LlmCostTracker::Ledger::Schema::CallTags).not_to receive(:current_schema_errors)
      expect(LlmCostTracker::Ledger::Schema::CallRollups).not_to receive(:current_schema_errors)
      described_class.current
    end

    it "reflects schema drift only after #reset! is invoked" do
      described_class.current
      ActiveRecord::Base.connection.remove_column(:llm_cost_tracker_calls, :pricing_mode)
      LlmCostTracker::Call.reset_column_information

      expect(described_class.current).to be_nil

      described_class.reset!
      drift = described_class.current
      expect(drift.message).to include("llm_cost_tracker_calls table does not match")
    end

    it "reports the calls table being missing" do
      described_class.reset!
      ActiveRecord::Base.connection.drop_table(:llm_cost_tracker_calls, force: :cascade)
      LlmCostTracker::Call.reset_column_information

      drift = described_class.current

      expect(drift.message).to include("not available yet")
    end
  end
end
