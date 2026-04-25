# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "yaml"

require "llm_cost_tracker/price_registry"
require "llm_cost_tracker/generators/llm_cost_tracker/prices_generator"

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
    expect(migration).to include("t.integer :cache_read_input_tokens")
    expect(migration).to include("t.integer :cache_write_input_tokens")
    expect(migration).to include("t.integer :hidden_output_tokens")
    expect(migration).to include("t.decimal :cache_read_input_cost")
    expect(migration).to include("t.decimal :cache_write_input_cost")
    expect(migration).to include("t.boolean :stream")
    expect(migration).to include("t.string  :usage_source")
    expect(migration).to include("t.string  :provider_response_id")
    expect(migration).to include("t.string  :pricing_mode")
    expect(migration).to include("t.jsonb :tags")
    expect(migration).to include("add_index :llm_api_calls, :tags, using: :gin if postgresql?")
    expect(migration).to include("create_table :llm_cost_tracker_period_totals")
    expect(migration).to include("add_index :llm_cost_tracker_period_totals, [:period, :period_start], unique: true")
    expect(migration).to include("add_index :llm_api_calls, :tracked_at")
    expect(migration).to include("add_index :llm_api_calls, [:provider, :tracked_at]")
    expect(migration).to include("add_index :llm_api_calls, [:model, :tracked_at]")
    expect(migration).to include("add_index :llm_api_calls, :stream")
    expect(migration).to include("add_index :llm_api_calls, :usage_source")
    expect(migration).to include("add_index :llm_api_calls, :provider_response_id")
    expect(migration).not_to match(/add_index :llm_api_calls, :provider$/)
    expect(migration).not_to match(/add_index :llm_api_calls, :model$/)
    expect(migration).to include("t.text :tags")
  end

  it "provides a complete initializer template" do
    initializer = template("initializer.rb.erb")

    expect(initializer).to include("config.enabled = true")
    expect(initializer).to include("config.storage_backend = :active_record")
    expect(initializer).to include("config.default_tags = -> { { environment: Rails.env } }")
    expect(initializer).to include("config.budget_exceeded_behavior = :notify")
    expect(initializer).to include("config.storage_error_behavior = :warn")
    expect(initializer).to include("config.unknown_pricing_behavior = :warn")
    expect(initializer).to include("config.log_level = :info")
    expect(initializer).to include("if options[:prices]")
    expect(initializer).to include("config.prices_file = Rails.root.join")
    expect(initializer).to include("# config.monthly_budget = 100.00")
    expect(initializer).to include("# config.daily_budget = 10.00")
    expect(initializer).to include("# config.per_call_budget = 1.00")
    expect(initializer).to include("# config.on_budget_exceeded")
    expect(initializer).to include("# config.pricing_overrides")
    expect(initializer).to include("# config.openai_compatible_providers")
    expect(initializer).to include("# config.report_tag_breakdowns")
    expect(initializer).to include("# config.custom_storage")
  end

  it "provides a latency upgrade migration" do
    migration = template("add_latency_ms_to_llm_api_calls.rb.erb")

    expect(migration).to include("class AddLatencyMsToLlmApiCalls")
    expect(migration).to include("add_column :llm_api_calls, :latency_ms, :integer")
    expect(migration).to include("remove_column :llm_api_calls, :latency_ms")
  end

  it "provides a period totals upgrade migration" do
    migration = template("add_period_totals_to_llm_cost_tracker.rb.erb")

    expect(migration).to include("class AddPeriodTotalsToLlmCostTracker")
    expect(migration).to include("create_table :llm_cost_tracker_period_totals")
    expect(migration).to include("backfill_legacy_monthly_totals if table_exists?(:llm_cost_tracker_monthly_totals)")
    expect(migration).to include("FROM llm_cost_tracker_monthly_totals legacy")
    expect(migration).to include("WHERE NOT EXISTS (")
    expect(migration).to include("FROM (")
    expect(migration).to include("aggregated.period_start")
    expect(migration).to include("add_index :llm_cost_tracker_period_totals, [:period, :period_start]")
    expect(migration).to include("SUM(total_cost)")
    expect(migration).to include("DATE_TRUNC('day', tracked_at)::date")
    expect(migration).to include("DATE_TRUNC('month', tracked_at)::date")
    expect(migration).to include("DATE(tracked_at)")
    expect(migration).to include("date(tracked_at)")
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

  it "provides a usage breakdown upgrade migration" do
    migration = template("add_usage_breakdown_to_llm_api_calls.rb.erb")

    expect(migration).to include("class AddUsageBreakdownToLlmApiCalls")
    expect(migration).to include("add_column :llm_api_calls, :cache_read_input_tokens, :integer")
    expect(migration).to include("add_column :llm_api_calls, :cache_write_input_tokens, :integer")
    expect(migration).to include("add_column :llm_api_calls, :hidden_output_tokens, :integer")
    expect(migration).to include("add_column :llm_api_calls, :cache_read_input_cost, :decimal")
    expect(migration).to include("add_column :llm_api_calls, :cache_write_input_cost, :decimal")
    expect(migration).to include("add_column :llm_api_calls, :pricing_mode, :string")
    expect(migration).to include("remove_column :llm_api_calls, :cache_read_input_tokens")
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

  it "generates a local prices snapshot from bundled prices" do
    expected = JSON.parse(File.read(LlmCostTracker::PriceRegistry::DEFAULT_PRICES_PATH))

    Dir.mktmpdir do |dir|
      LlmCostTracker::Generators::PricesGenerator.start([], destination_root: dir)
      path = File.join(dir, "config/llm_cost_tracker_prices.yml")
      parsed = YAML.safe_load_file(path, aliases: false)

      expect(parsed.fetch("metadata")).to eq(expected.fetch("metadata"))
      expect(parsed.fetch("models")).to eq(expected.fetch("models"))
    end
  end
end
