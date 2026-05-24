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

    it "includes every TokenUsage field" do
      missing = LlmCostTracker::TokenUsage.members.map(&:to_s) - schema_columns
      message = "TokenUsage members not declared in schema: #{missing.join(', ')}; " \
                "add migration and update CURRENT_SCHEMA_COLUMNS"

      expect(missing).to be_empty, message
    end

    it "stores only the total_cost denormalized header amount" do
      expect(schema_columns).to include("total_cost")
      LlmCostTracker::Billing::Components::TOKEN_PRICED.each do |component|
        expect(schema_columns).not_to include(component.cost_key.to_s)
      end
    end

    it "does not contain unknown data columns" do
      known_columns = fixed_schema_columns + LlmCostTracker::TokenUsage.members.map(&:to_s)
      unknown = schema_columns - known_columns

      expect(unknown).to be_empty, "Unknown schema columns: #{unknown.join(', ')}"
    end
  end

  describe ".current_schema_errors event_id uniqueness" do
    include_context "with mounted llm cost tracker engine"

    it "is silent when the event_id unique index is present" do
      expect(described_class.current_schema_errors).not_to include(match(/event_id/))
    end

    it "reports a missing unique index when it has been dropped" do
      ActiveRecord::Base.connection.remove_index(:llm_cost_tracker_calls, :event_id)
      LlmCostTracker::Call.reset_column_information
      described_class.instance_variable_set(:@schema_capabilities, nil)

      expect(described_class.current_schema_errors).to include("missing unique index: event_id")
    end

    it "reports a missing non-unique index when it has been dropped" do
      ActiveRecord::Base.connection.remove_index(:llm_cost_tracker_calls, %i[provider tracked_at])
      LlmCostTracker::Call.reset_column_information
      described_class.instance_variable_set(:@schema_capabilities, nil)

      expect(described_class.current_schema_errors).to include("missing index: provider, tracked_at")
    end

    it "surfaces index lookup failures instead of reporting a false green" do
      allow(LlmCostTracker::Call.connection).to receive(:index_exists?).and_raise("connection lost")
      described_class.instance_variable_set(:@schema_capabilities, nil)

      expect { described_class.current_schema_errors }.to raise_error("connection lost")
    end
  end
end
