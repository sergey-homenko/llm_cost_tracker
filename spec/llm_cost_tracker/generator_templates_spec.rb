# frozen_string_literal: true

require "spec_helper"

RSpec.describe "generator templates" do
  def template(name)
    path = File.expand_path(
      "../../lib/llm_cost_tracker/generators/llm_cost_tracker/templates/#{name}",
      __dir__
    )

    File.read(path)
  end

  it "creates JSONB tags and a GIN index for PostgreSQL installs" do
    migration = template("create_llm_api_calls.rb.erb")

    expect(migration).to include("precision: 20, scale: 8")
    expect(migration).to include("t.integer :latency_ms")
    expect(migration).to include("t.jsonb :tags")
    expect(migration).to include("add_index :llm_api_calls, :tags, using: :gin if postgresql?")
    expect(migration).to include("t.text :tags")
  end

  it "provides a latency upgrade migration" do
    migration = template("add_latency_ms_to_llm_api_calls.rb.erb")

    expect(migration).to include("class AddLatencyMsToLlmApiCalls")
    expect(migration).to include("add_column :llm_api_calls, :latency_ms, :integer")
    expect(migration).to include("remove_column :llm_api_calls, :latency_ms")
  end

  it "provides a cost precision upgrade migration" do
    migration = template("upgrade_llm_api_call_cost_precision.rb.erb")

    expect(migration).to include("class UpgradeLlmApiCallCostPrecision")
    expect(migration).to include("precision: 20, scale: 8")
    expect(migration).to include("precision: 12, scale: 8")
  end

  it "provides a PostgreSQL JSONB upgrade migration" do
    migration = template("upgrade_llm_api_call_tags_to_jsonb.rb.erb")

    expect(migration).to include("class UpgradeLlmApiCallTagsToJsonb")
    expect(migration).to include("change_column(")
    expect(migration).to include("using: \"CASE WHEN tags IS NULL")
    expect(migration).to include("add_index :llm_api_calls, :tags, using: :gin")
  end
end
