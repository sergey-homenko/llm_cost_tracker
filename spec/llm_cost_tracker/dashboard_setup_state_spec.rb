# frozen_string_literal: true

require "spec_helper"

require_relative "../dummy/config/environment"

RSpec.describe LlmCostTracker::DashboardSetupState do
  include_context "with mounted llm cost tracker engine"

  describe ".current" do
    it "returns OK when every required table matches the current schema" do
      state = described_class.current

      expect(state.setup_required?).to be false
    end

    it "memoizes the schema check across repeat calls so dashboard requests don't re-query metadata" do
      described_class.current

      expect(LlmCostTracker::Ledger::Schema::Calls).not_to receive(:current_schema_errors)
      described_class.current
    end

    it "reflects schema drift only after #reset! is invoked" do
      described_class.current
      ActiveRecord::Base.connection.remove_column(:llm_cost_tracker_calls, :pricing_mode)
      LlmCostTracker::Call.reset_column_information

      expect(described_class.current.setup_required?).to be false

      described_class.reset!
      drifted = described_class.current
      expect(drifted.setup_required?).to be true
      expect(drifted.message).to include("llm_cost_tracker_calls table does not match")
    end

    it "reports the calls table being missing as a setup-required state" do
      described_class.reset!
      ActiveRecord::Base.connection.drop_table(:llm_cost_tracker_calls, force: :cascade)
      LlmCostTracker::Call.reset_column_information

      state = described_class.current

      expect(state.setup_required?).to be true
      expect(state.message).to include("not available yet")
    end
  end
end
