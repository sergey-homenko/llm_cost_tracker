# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Doctor::SchemaGenerators do
  it "uses token usage migration when extended cache-write columns were never added" do
    generators = described_class.for_missing_columns(
      %w[cache_write_extended_input_tokens cache_write_extended_input_cost],
      columns: {}
    )

    expect(generators).to eq(["bin/rails generate llm_cost_tracker:add_token_usage"])
  end

  it "uses foundation rename when released cache-write columns are still on old names" do
    columns = {
      "cache_write_1h_input_tokens" => double,
      "cache_write_1h_input_cost" => double
    }
    generators = described_class.for_missing_columns(
      %w[cache_write_extended_input_tokens cache_write_extended_input_cost],
      columns: columns
    )

    expect(generators).to eq(["bin/rails generate llm_cost_tracker:upgrade_schema_foundation"])
  end
end
