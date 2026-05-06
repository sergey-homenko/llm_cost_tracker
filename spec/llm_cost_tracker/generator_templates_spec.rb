# frozen_string_literal: true

require "spec_helper"
require "erb"
require "fileutils"
require "json"
require "tmpdir"
require "yaml"

require "llm_cost_tracker/pricing/registry"
require "llm_cost_tracker/generators/llm_cost_tracker/add_billing_generator"
require "llm_cost_tracker/generators/llm_cost_tracker/add_call_rollups_generator"
require "llm_cost_tracker/generators/llm_cost_tracker/add_capture_dimensions_generator"
require "llm_cost_tracker/generators/llm_cost_tracker/add_ingestion_generator"
require "llm_cost_tracker/generators/llm_cost_tracker/add_token_usage_generator"
require "llm_cost_tracker/generators/llm_cost_tracker/install_generator"
require "llm_cost_tracker/generators/llm_cost_tracker/prices_generator"
require "llm_cost_tracker/generators/llm_cost_tracker/upgrade_schema_foundation_generator"

RSpec.describe "generator templates" do
  let(:migration_version) { "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]" }

  def template(name)
    path = File.expand_path(
      "../../lib/llm_cost_tracker/generators/llm_cost_tracker/templates/#{name}",
      __dir__
    )

    File.read(path)
  end

  def render_migration_template(name)
    ERB.new(template(name), trim_mode: "-").result(binding)
  end

  it "creates calls, line items, tags, and ingestion tables for PostgreSQL installs" do
    migration = render_migration_template("create_llm_cost_tracker_calls.rb.erb")

    expect(migration).to include("require \"llm_cost_tracker/ledger/schema/adapter\"")
    expect(migration).to include("t.string  :event_id")
    expect(migration).to include("precision: 20, scale: 8")
    expect(migration).to include("t.integer :latency_ms")
    expect(migration).to include("t.integer :cache_read_input_tokens")
    expect(migration).to include("t.integer :cache_write_input_tokens")
    expect(migration).to include("t.integer :cache_write_extended_input_tokens")
    expect(migration).to include("t.integer :audio_input_tokens")
    expect(migration).to include("t.integer :audio_output_tokens")
    expect(migration).to include("t.integer :hidden_output_tokens")
    expect(migration).to include("t.decimal :cache_read_input_cost")
    expect(migration).to include("t.decimal :cache_write_input_cost")
    expect(migration).to include("t.decimal :cache_write_extended_input_cost")
    expect(migration).to include("t.decimal :audio_input_cost")
    expect(migration).to include("t.decimal :audio_output_cost")
    expect(migration).to include("t.boolean :stream")
    expect(migration).to include("t.string  :usage_source")
    expect(migration).to include("t.string  :provider_response_id")
    expect(migration).to include("t.string  :provider_project_id")
    expect(migration).to include("t.string  :provider_api_key_id")
    expect(migration).to include("t.string  :provider_workspace_id")
    expect(migration).to include("t.boolean :batch")
    expect(migration).to include("t.string  :pricing_mode")
    expect(migration).to include("t.string  :cost_status")
    expect(migration).to include("t.jsonb :pricing_snapshot")
    expect(migration).not_to include("t.jsonb :tags")
    expect(migration).not_to include("add_index :llm_cost_tracker_calls, :tags")
    expect(migration).to include("create_table :llm_cost_tracker_call_rollups")
    expect(migration).to include("create_table :llm_cost_tracker_call_line_items")
    expect(migration).to include("create_table :llm_cost_tracker_call_tags")
    expect(migration).to include("create_table :llm_cost_tracker_ingestion_inbox_entries")
    expect(migration).to include("create_table :llm_cost_tracker_ingestion_leases")
    expect(migration).not_to include("create_table :llm_cost_tracker_service_charges")
    expect(migration).to include("add_index :llm_cost_tracker_call_rollups, [:period, :period_start], unique: true")
    expect(migration).to include("add_index :llm_cost_tracker_calls, :event_id, unique: true")
    expect(migration).to include("add_index :llm_cost_tracker_ingestion_inbox_entries, :event_id, unique: true")
    expect(migration).to include("add_index :llm_cost_tracker_ingestion_inbox_entries, [:tracked_at, :attempts]")
    expect(migration).not_to include("add_index :llm_cost_tracker_ingestion_inbox_entries, :tracked_at")
    expect(migration).to include("add_index :llm_cost_tracker_ingestion_leases, :name, unique: true")
    expect(migration).to include("add_index :llm_cost_tracker_calls, :tracked_at")
    expect(migration).to include("add_index :llm_cost_tracker_calls, [:provider, :tracked_at]")
    expect(migration).to include("add_index :llm_cost_tracker_calls, [:model, :tracked_at]")
    expect(migration).not_to include("add_index :llm_cost_tracker_calls, :stream")
    expect(migration).not_to include("add_index :llm_cost_tracker_calls, :usage_source")
    expect(migration).to include("add_index :llm_cost_tracker_calls, :provider_response_id")
    expect(migration).to include("add_index :llm_cost_tracker_call_line_items, [:llm_cost_tracker_call_id, :position]")
    expect(migration).to include("add_index :llm_cost_tracker_call_tags, [:key, :value]")
    expect(migration).not_to match(/add_index :llm_cost_tracker_calls, :provider$/)
    expect(migration).not_to match(/add_index :llm_cost_tracker_calls, :model$/)
    expect(migration).not_to include("t.json :tags")
    expect(migration).to include("LLM Cost Tracker supports PostgreSQL and MySQL only")
    expect(migration).to include("LlmCostTracker::Ledger::Schema::Adapter.postgresql?(connection)")
    expect(migration).to include("LlmCostTracker::Ledger::Schema::Adapter.mysql?(connection)")
  end

  it "provides a complete initializer template" do
    initializer = template("initializer.rb.erb")

    expect(initializer).to include("config.enabled = true")
    expect(initializer).to include("config.default_tags = -> { { environment: Rails.env } }")
    expect(initializer).to include("config.budget_exceeded_behavior = :notify")
    expect(initializer).to include("config.unknown_pricing_behavior = :warn")
    expect(initializer).to include("config.log_level = :info")
    expect(initializer).to include("# config.instrument :openai")
    expect(initializer).to include("# config.instrument :anthropic")
    expect(initializer).to include("# config.instrument :ruby_llm")
    expect(initializer).to include("if options[:prices]")
    expect(initializer).to include("config.prices_file = Rails.root.join")
    expect(initializer).to include("# config.monthly_budget = 100.00")
    expect(initializer).to include("# config.daily_budget = 10.00")
    expect(initializer).to include("# config.per_call_budget = 1.00")
    expect(initializer).to include("# config.max_tag_count = 50")
    expect(initializer).to include("# config.max_tag_value_bytesize = 1024")
    expect(initializer).to include("# config.redacted_tag_keys")
    expect(initializer).to include("# config.on_budget_exceeded")
    expect(initializer).to include("# config.pricing_overrides")
    expect(initializer).to include("# config.openai_compatible_providers")
    expect(initializer).to include("# config.report_tag_breakdowns")
    expect(initializer).not_to include("config.storage_backend")
    expect(initializer).not_to include("config.custom_storage")
  end

  it "provides a latency upgrade migration" do
    migration = template("add_latency_ms_to_llm_cost_tracker_calls.rb.erb")

    expect(migration).to include("class AddLatencyMsToLlmCostTrackerCalls")
    expect(migration).to include("add_column :llm_cost_tracker_calls, :latency_ms, :integer")
    expect(migration).to include("remove_column :llm_cost_tracker_calls, :latency_ms")
  end

  it "provides a call rollups upgrade migration" do
    migration = template("add_call_rollups_to_llm_cost_tracker.rb.erb")

    expect(migration).to include("class AddCallRollupsToLlmCostTracker")
    expect(migration).to include("create_table :llm_cost_tracker_call_rollups")
    expect(migration).to include("backfill_legacy_monthly_totals if table_exists?(:llm_cost_tracker_monthly_totals)")
    expect(migration).to include("FROM llm_cost_tracker_monthly_totals legacy")
    expect(migration).to include("WHERE NOT EXISTS (")
    expect(migration).to include("FROM (")
    expect(migration).to include("aggregated.period_start")
    expect(migration).to include("add_index :llm_cost_tracker_call_rollups, [:period, :period_start]")
    expect(migration).to include("SUM(total_cost)")
    expect(migration).to include("DATE_TRUNC('day', tracked_at)::date")
    expect(migration).to include("DATE_TRUNC('month', tracked_at)::date")
    expect(migration).to include("require \"llm_cost_tracker/ledger/schema/adapter\"")
    expect(migration).to include("LlmCostTracker::Ledger::Schema::Adapter.postgresql?(connection)")
    expect(migration).to include("LlmCostTracker::Ledger::Schema::Adapter.mysql?(connection)")
    expect(migration).to include("DATE(tracked_at)")
    expect(migration).to include("DATE_FORMAT(tracked_at, '%Y-%m-01')")
    expect(migration).to include("LLM Cost Tracker supports PostgreSQL and MySQL only")
  end

  it "provides a durable ingestion upgrade migration" do
    migration = template("add_ingestion_to_llm_cost_tracker.rb.erb")

    expect(migration).to include("class AddIngestionToLlmCostTracker")
    expect(migration).to include("add_column :llm_cost_tracker_calls, :event_id")
    expect(migration).to include("add_index :llm_cost_tracker_calls, :event_id, unique: true")
    expect(migration).to include("create_table :llm_cost_tracker_ingestion_inbox_entries")
    expect(migration).to include("create_table :llm_cost_tracker_ingestion_leases")
    expect(migration).to include("add_index :llm_cost_tracker_ingestion_inbox_entries, :event_id, unique: true")
    expect(migration).to include("add_index :llm_cost_tracker_ingestion_inbox_entries, [:tracked_at, :attempts]")
    expect(migration).to include("remove_index :llm_cost_tracker_ingestion_inbox_entries, :tracked_at")
    expect(migration).not_to include("add_index :llm_cost_tracker_ingestion_inbox_entries, :tracked_at")
    expect(migration).to include("add_index :llm_cost_tracker_ingestion_leases, :name, unique: true")
    expect(migration).not_to include("t.string   :provider, null: false")
    expect(migration).not_to include("t.string   :model, null: false")
  end

  it "provides a capture dimensions upgrade migration" do
    migration = template("add_capture_dimensions_to_llm_cost_tracker_calls.rb.erb")

    expect(migration).to include("class AddCaptureDimensionsToLlmCostTrackerCalls")
    expect(migration).to include("add_column :llm_cost_tracker_calls, :provider_project_id, :string")
    expect(migration).to include("add_column :llm_cost_tracker_calls, :provider_api_key_id, :string")
    expect(migration).to include("add_column :llm_cost_tracker_calls, :provider_workspace_id, :string")
    expect(migration).to include("add_column :llm_cost_tracker_calls, :batch, :boolean, null: false, default: false")
  end

  it "generates a durable ingestion migration" do
    Dir.mktmpdir do |dir|
      LlmCostTracker::Generators::AddIngestionGenerator.start([], destination_root: dir)
      paths = Dir[File.join(dir, "db/migrate/*add_ingestion_to_llm_cost_tracker.rb")]

      expect(paths.size).to eq(1)
      expect(File.read(paths.first)).to include("class AddIngestionToLlmCostTracker")
    end
  end

  it "generates a capture dimensions migration" do
    Dir.mktmpdir do |dir|
      LlmCostTracker::Generators::AddCaptureDimensionsGenerator.start([], destination_root: dir)
      paths = Dir[File.join(dir, "db/migrate/*add_capture_dimensions_to_llm_cost_tracker_calls.rb")]

      expect(paths.size).to eq(1)
      expect(File.read(paths.first)).to include("class AddCaptureDimensionsToLlmCostTrackerCalls")
    end
  end

  it "can run the install generator twice" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config/application.rb"), %(require "rails/all"\n))
      File.write(File.join(dir, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")

      2.times { LlmCostTracker::Generators::InstallGenerator.start(["--dashboard", "--prices"], destination_root: dir) }

      expect(Dir[File.join(dir, "db/migrate/*create_llm_cost_tracker_calls.rb")].size).to eq(1)
      expect(File).to exist(File.join(dir, "config/llm_cost_tracker_prices.yml"))
      expect(File.read(File.join(dir, "config/routes.rb")).scan("mount LlmCostTracker::Engine").size).to eq(1)
    end
  end

  it "provides a streaming upgrade migration" do
    migration = template("add_streaming_to_llm_cost_tracker_calls.rb.erb")

    expect(migration).to include("class AddStreamingToLlmCostTrackerCalls")
    expect(migration).to include("add_column :llm_cost_tracker_calls, :stream, :boolean")
    expect(migration).to include("add_column :llm_cost_tracker_calls, :usage_source, :string")
    expect(migration).not_to include("add_index")
    expect(migration).to include("remove_column :llm_cost_tracker_calls, :stream")
    expect(migration).to include("remove_column :llm_cost_tracker_calls, :usage_source")
  end

  it "provides a provider response id upgrade migration" do
    migration = template("add_provider_response_id_to_llm_cost_tracker_calls.rb.erb")

    expect(migration).to include("class AddProviderResponseIdToLlmCostTrackerCalls")
    expect(migration).to include("add_column :llm_cost_tracker_calls, :provider_response_id, :string")
    expect(migration).to include("add_index :llm_cost_tracker_calls, :provider_response_id")
    expect(migration).to include("remove_column :llm_cost_tracker_calls, :provider_response_id")
  end

  it "provides a token usage upgrade migration" do
    migration = render_migration_template("add_token_usage_to_llm_cost_tracker_calls.rb.erb")

    expect(migration).to include("class AddTokenUsageToLlmCostTrackerCalls")
    expect(migration).to include("add_column :llm_cost_tracker_calls, :cache_read_input_tokens, :integer")
    expect(migration).to include("add_column :llm_cost_tracker_calls, :cache_write_input_tokens, :integer")
    expect(migration).to include("add_column :llm_cost_tracker_calls, :cache_write_extended_input_tokens, :integer")
    expect(migration).to include("add_column :llm_cost_tracker_calls, :audio_input_tokens, :integer")
    expect(migration).to include("add_column :llm_cost_tracker_calls, :audio_output_tokens, :integer")
    expect(migration).to include("add_column :llm_cost_tracker_calls, :hidden_output_tokens, :integer")
    expect(migration).to include("add_column :llm_cost_tracker_calls, :cache_read_input_cost, :decimal")
    expect(migration).to include("add_column :llm_cost_tracker_calls, :cache_write_input_cost, :decimal")
    expect(migration).to include("add_column :llm_cost_tracker_calls, :cache_write_extended_input_cost, :decimal")
    expect(migration).to include("add_column :llm_cost_tracker_calls, :audio_input_cost, :decimal")
    expect(migration).to include("add_column :llm_cost_tracker_calls, :audio_output_cost, :decimal")
    expect(migration).to include("add_column :llm_cost_tracker_calls, :pricing_mode, :string")
    expect(migration).to include("remove_column :llm_cost_tracker_calls, :cache_read_input_tokens")
    expect(migration).not_to include("cache_write_1h_input")
  end

  it "provides a schema foundation rename migration" do
    migration = render_migration_template("upgrade_schema_foundation.rb.erb")

    expect(migration).to include("class UpgradeLlmCostTrackerSchemaFoundation")
    expect(migration).to include("llm_api_calls: :llm_cost_tracker_calls")
    expect(migration).to include("llm_cost_tracker_period_totals: :llm_cost_tracker_call_rollups")
    expect(migration).to include(
      "llm_cost_tracker_inbox_events: :llm_cost_tracker_ingestion_inbox_entries"
    )
    expect(migration).to include("llm_cost_tracker_ingestor_leases: :llm_cost_tracker_ingestion_leases")
    expect(migration).to include("llm_api_call_id: :llm_cost_tracker_call_id")
    expect(migration).to include("cache_write_1h_input_tokens: :cache_write_extended_input_tokens")
    expect(migration).to include("cache_write_1h_input_cost: :cache_write_extended_input_cost")
    expect(migration).to include("rename_table old_table, new_table")
    expect(migration).to include("Both \#{old_table} and \#{new_table} exist")
    expect(migration).to include("rename_tables(TABLE_RENAMES.invert)")
    expect(migration).to include("rename_service_charge_columns(SERVICE_CHARGE_COLUMN_RENAMES.invert)")
    expect(migration).to include("rename_call_columns(CALL_COLUMN_RENAMES.invert)")
    expect(migration).to include("rename_column :llm_cost_tracker_calls, old_column, new_column")
    expect(migration).to include("Both llm_cost_tracker_calls.\#{old_column}")
    expect(migration).to include(
      "rename_column :llm_cost_tracker_service_charges, old_column, new_column"
    )
  end

  it "generates a schema foundation migration" do
    Dir.mktmpdir do |dir|
      LlmCostTracker::Generators::UpgradeSchemaFoundationGenerator.start([], destination_root: dir)
      paths = Dir[File.join(dir, "db/migrate/*upgrade_llm_cost_tracker_schema_foundation.rb")]

      expect(paths.size).to eq(1)
      expect(File.read(paths.first)).to include("class UpgradeLlmCostTrackerSchemaFoundation")
    end
  end

  it "provides a billing audit upgrade migration" do
    migration = render_migration_template("add_billing_to_llm_cost_tracker.rb.erb")

    expect(migration).to include("class AddBillingToLlmCostTracker")
    expect(migration).to include("add_column :llm_cost_tracker_calls, :cost_status, :string")
    expect(migration).to include("add_column :llm_cost_tracker_calls, :pricing_snapshot")
    expect(migration).to include("create_table :llm_cost_tracker_service_charges")
    expect(migration).to include("create_service_charges_table unless table_exists?")
    expect(migration).to include("t.string :component, null: false")
    expect(migration).to include("t.decimal :quantity, precision: 30, scale: 10")
    expect(migration).to include("add_index :llm_cost_tracker_service_charges, :charge_id, unique: true")
    expect(migration).to include("drop_table :llm_cost_tracker_service_charges")
  end

  it "provides a cost precision upgrade migration" do
    migration = template("upgrade_llm_cost_tracker_call_cost_precision.rb.erb")

    expect(migration).to include("class UpgradeLlmCostTrackerCallCostPrecision")
    expect(migration).to include("precision: 20, scale: 8")
    expect(migration).to include("precision: 12, scale: 8")
  end

  it "provides a PostgreSQL JSONB upgrade migration" do
    migration = template("upgrade_llm_cost_tracker_call_tags_to_jsonb.rb.erb")

    expect(migration).to include("class UpgradeLlmCostTrackerCallTagsToJsonb")
    expect(migration).to include("change_column(")
    expect(migration).to include("using: \"CASE WHEN tags IS NULL")
    expect(migration).to include("add_index :llm_cost_tracker_calls, :tags, using: :gin")
    expect(migration).to include("rewrites the table on PostgreSQL")
    expect(migration).to include("LlmCostTracker::Ledger::Schema::Adapter.postgresql?(connection)")
  end

  it "generates a local prices snapshot from bundled prices" do
    expected = JSON.parse(File.read(LlmCostTracker::Pricing::Registry::DEFAULT_PRICES_PATH))

    Dir.mktmpdir do |dir|
      LlmCostTracker::Generators::PricesGenerator.start([], destination_root: dir)
      path = File.join(dir, "config/llm_cost_tracker_prices.yml")
      parsed = YAML.safe_load_file(path, aliases: false)

      expect(parsed.fetch("metadata")).to eq(expected.fetch("metadata"))
      expect(parsed.fetch("models")).to eq(expected.fetch("models"))
    end
  end
end
