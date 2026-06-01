# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Ledger::Schema::Calls do
  describe "required_columns" do
    let(:schema_columns) { described_class.required_columns }
    let(:fixed_schema_columns) do
      %w[
        event_id
        provider
        model
        latency_ms
        stream
        usage_source
        provider_response_id
        provider_project_id
        provider_api_key_id
        provider_workspace_id
        batch
        pricing_mode
        cost_status
        pricing_snapshot
        total_cost
        tracked_at
      ]
    end

    it "includes every Usage::TokenUsage field" do
      missing = LlmCostTracker::Usage::TokenUsage.members.map(&:to_s) - schema_columns
      message = "Usage::TokenUsage members not declared in schema: #{missing.join(', ')}; " \
                "add migration and update the columns declaration"

      expect(missing).to be_empty, message
    end

    it "stores only the total_cost denormalized header amount" do
      expect(schema_columns).to include("total_cost")
      LlmCostTracker::Usage::Dimension::TOKEN_PRICED.each do |component|
        expect(schema_columns).not_to include(component.cost_key.to_s)
      end
    end

    it "does not contain unknown data columns" do
      known_columns = fixed_schema_columns + LlmCostTracker::Usage::TokenUsage.members.map(&:to_s)
      unknown = schema_columns - known_columns

      expect(unknown).to be_empty, "Unknown schema columns: #{unknown.join(', ')}"
    end
  end
end
