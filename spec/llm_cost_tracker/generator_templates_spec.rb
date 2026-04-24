# frozen_string_literal: true

require "spec_helper"
require "yaml"

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
    expect(migration).to include("t.boolean :stream")
    expect(migration).to include("t.string  :usage_source")
    expect(migration).to include("t.string  :provider_response_id")
    expect(migration).to include("t.jsonb :tags")
    expect(migration).to include("add_index :llm_api_calls, :tags, using: :gin if postgresql?")
    expect(migration).to include("create_table :llm_cost_tracker_monthly_totals")
    expect(migration).to include("add_index :llm_cost_tracker_monthly_totals, :month_start, unique: true")
    expect(migration).to include("add_index :llm_api_calls, :stream")
    expect(migration).to include("add_index :llm_api_calls, :usage_source")
    expect(migration).to include("add_index :llm_api_calls, :provider_response_id")
    expect(migration).to include("t.text :tags")
  end

  it "provides a latency upgrade migration" do
    migration = template("add_latency_ms_to_llm_api_calls.rb.erb")

    expect(migration).to include("class AddLatencyMsToLlmApiCalls")
    expect(migration).to include("add_column :llm_api_calls, :latency_ms, :integer")
    expect(migration).to include("remove_column :llm_api_calls, :latency_ms")
  end

  it "provides a monthly totals upgrade migration" do
    migration = template("add_monthly_totals_to_llm_cost_tracker.rb.erb")

    expect(migration).to include("class AddMonthlyTotalsToLlmCostTracker")
    expect(migration).to include("create_table :llm_cost_tracker_monthly_totals")
    expect(migration).to include("SUM(total_cost)")
    expect(migration).to include("DATE_TRUNC('month', tracked_at)::date")
    expect(migration).to include("DATE_FORMAT(tracked_at, '%Y-%m-01')")
    expect(migration).to include("strftime('%Y-%m-01', tracked_at)")
  end

  it "provides a streaming upgrade migration" do
    migration = template("add_streaming_to_llm_api_calls.rb.erb")

    expect(migration).to include("class AddStreamingToLlmApiCalls")
    expect(migration).to include("add_column :llm_api_calls, :stream, :boolean")
    expect(migration).to include("add_column :llm_api_calls, :usage_source, :string")
    expect(migration).to include("remove_column :llm_api_calls, :stream")
    expect(migration).to include("remove_column :llm_api_calls, :usage_source")
  end

  it "provides a provider response id upgrade migration" do
    migration = template("add_provider_response_id_to_llm_api_calls.rb.erb")

    expect(migration).to include("class AddProviderResponseIdToLlmApiCalls")
    expect(migration).to include("add_column :llm_api_calls, :provider_response_id, :string")
    expect(migration).to include("add_index :llm_api_calls, :provider_response_id")
    expect(migration).to include("remove_column :llm_api_calls, :provider_response_id")
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
    expect(migration).to include("rewrites the table on PostgreSQL")
  end

  it "provides a valid local prices override template" do
    prices_template = template("llm_cost_tracker_prices.yml.erb")
    parsed = YAML.safe_load(prices_template.gsub(/^#.*$/, ""), aliases: false)
    supported_keys = %w[input output cached_input cache_read_input cache_creation_input _source _updated _notes]
    example_keys = prices_template.scan(/^#\s+([a-z_]+):/).flatten - ["models"]

    expect(parsed).to eq("models" => nil)
    expect(example_keys - supported_keys).to be_empty
    expect(prices_template).to include("Supported price keys")
    expect(prices_template).to include("_updated")
  end
end
