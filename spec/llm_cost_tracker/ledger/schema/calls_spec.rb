# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Ledger::Schema::Calls do
  describe "CURRENT_SCHEMA_COLUMNS" do
    let(:schema_columns) { described_class::CURRENT_SCHEMA_COLUMNS }
    let(:fixed_schema_columns) do
      %w[
        event_id
        provider
        model
        latency_ms
        stream
        usage_source
        provider_response_id
        pricing_mode
        tags
        tracked_at
      ]
    end

    it "includes every TokenUsage field" do
      missing = LlmCostTracker::TokenUsage.members.map(&:to_s) - schema_columns
      message = "TokenUsage members not declared in schema: #{missing.join(', ')}; " \
                "add migration and update CURRENT_SCHEMA_COLUMNS"

      expect(missing).to be_empty, message
    end

    it "includes every Pricing cost column" do
      missing = LlmCostTracker::Pricing::COST_KEYS.map(&:to_s) - schema_columns
      message = "Pricing cost keys not declared in schema: #{missing.join(', ')}; " \
                "add migration and update CURRENT_SCHEMA_COLUMNS"

      expect(missing).to be_empty, message
    end

    it "does not contain unknown data columns" do
      known_columns = fixed_schema_columns +
                      LlmCostTracker::TokenUsage.members.map(&:to_s) +
                      LlmCostTracker::Pricing::COST_KEYS.map(&:to_s)
      unknown = schema_columns - known_columns

      expect(unknown).to be_empty, "Unknown schema columns: #{unknown.join(', ')}"
    end
  end
end
