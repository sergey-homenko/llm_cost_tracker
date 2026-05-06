# frozen_string_literal: true

require "spec_helper"
require "erb"
require "fileutils"
require "json"
require "tmpdir"
require "yaml"

require "llm_cost_tracker/pricing/registry"
require "llm_cost_tracker/generators/llm_cost_tracker/install_generator"
require "llm_cost_tracker/generators/llm_cost_tracker/prices_generator"

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
    expect(migration).to include("t.decimal :total_cost")
    expect(migration).not_to include("t.decimal :input_cost")
    expect(migration).not_to include("t.decimal :output_cost")
    expect(migration).not_to include("t.decimal :cache_read_input_cost")
    expect(migration).not_to include("t.decimal :audio_input_cost")
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
    expect(migration).to include("add_index :llm_cost_tracker_call_tags, :key")
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
