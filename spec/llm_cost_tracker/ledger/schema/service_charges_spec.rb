# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Ledger::Schema::ServiceCharges do
  describe "REQUIRED_COLUMNS" do
    it "contains the service charge storage contract" do
      expect(described_class::REQUIRED_COLUMNS).to include(
        "llm_api_call_id",
        "charge_id",
        "component",
        "unit",
        "quantity",
        "cost",
        "cost_status",
        "details"
      )
    end
  end
end
