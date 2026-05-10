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
require "llm_cost_tracker/generators/llm_cost_tracker/reconciliation_generator"
require "llm_cost_tracker/generators/llm_cost_tracker/upgrade_call_rollups_provider_generator"
require "llm_cost_tracker/generators/llm_cost_tracker/durable_ingestion_generator"
require "llm_cost_tracker/generators/llm_cost_tracker/call_rollups_generator"

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

  def render_install_initializer(prices:)
    options = { prices: prices }
    ERB.new(template("initializer.rb.erb"), trim_mode: "-").result(binding)
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
    expect(migration).not_to include("create_table :llm_cost_tracker_call_rollups")
    expect(migration).to include("create_table :llm_cost_tracker_call_line_items")
    expect(migration).to include("create_table :llm_cost_tracker_call_tags")
    expect(migration).not_to include("create_table :llm_cost_tracker_ingestion_inbox_entries")
    expect(migration).not_to include("create_table :llm_cost_tracker_ingestion_leases")
    expect(migration).not_to include("create_table :llm_cost_tracker_service_charges")
    expect(migration).not_to include("add_index :llm_cost_tracker_call_rollups, [:period, :period_start, :currency, :provider], unique: true")
    expect(migration).to include("add_index :llm_cost_tracker_calls, :event_id, unique: true")
    expect(migration).not_to include("add_index :llm_cost_tracker_ingestion_inbox_entries, :event_id, unique: true")
    expect(migration).not_to include("add_index :llm_cost_tracker_ingestion_leases, :name, unique: true")
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

  it "renders prices_file exactly once when --prices is enabled" do
    rendered = render_install_initializer(prices: true)

    occurrences = rendered.scan(/config\.prices_file\s*=/)
    expect(occurrences.size).to eq(1)
    expect(rendered).to include('config.prices_file = Rails.root.join("config/llm_cost_tracker_prices.yml")')
  end

  it "renders prices_file commented out exactly once when --prices is not enabled" do
    rendered = render_install_initializer(prices: false)

    occurrences = rendered.scan(/config\.prices_file\s*=/)
    expect(occurrences.size).to eq(1)
    expect(rendered).to include('# config.prices_file = Rails.root.join("config/llm_cost_tracker_prices.yml")')
  end

  it "can run the install generator twice" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config/application.rb"), %(require "rails/all"\n))
      File.write(File.join(dir, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")

      2.times { LlmCostTracker::Generators::InstallGenerator.start(["--dashboard", "--prices"], destination_root: dir) }

      expect(Dir[File.join(dir, "db/migrate/*create_llm_cost_tracker_calls.rb")].size).to eq(1)
      expect(File).to exist(File.join(dir, "config/llm_cost_tracker_prices.yml"))
    end
  end

  it "does not auto-mount the dashboard route (auth is host app's responsibility)" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config/application.rb"), %(require "rails/all"\n))
      File.write(File.join(dir, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")

      LlmCostTracker::Generators::InstallGenerator.start(["--dashboard"], destination_root: dir)

      expect(File.read(File.join(dir, "config/routes.rb"))).not_to include("mount LlmCostTracker::Engine")
    end
  end

  it "generates the optional reconciliation migration with provider invoices and imports tables" do
    Dir.mktmpdir do |dir|
      LlmCostTracker::Generators::ReconciliationGenerator.start([], destination_root: dir)

      migration_path = Dir[File.join(dir, "db/migrate/*_create_llm_cost_tracker_reconciliation.rb")].first
      expect(migration_path).not_to be_nil

      migration = File.read(migration_path)
      expect(migration).to include("create_table :llm_cost_tracker_provider_invoices")
      expect(migration).to include("create_table :llm_cost_tracker_provider_invoice_imports")
      expect(migration).to include("add_index :llm_cost_tracker_provider_invoices, :external_id")
      expect(migration).to include("add_index :llm_cost_tracker_provider_invoice_imports, [:source, :started_at]")
    end
  end

  describe "upgrade_call_rollups_provider generator" do
    it "writes a guarded provider-column migration" do
      Dir.mktmpdir do |dir|
        LlmCostTracker::Generators::UpgradeCallRollupsProviderGenerator.start([], destination_root: dir)

        migration_path = Dir[
          File.join(dir, "db/migrate/*_upgrade_llm_cost_tracker_call_rollups_provider.rb")
        ].first
        expect(migration_path).not_to be_nil

        migration = File.read(migration_path)
        expect(migration).to include("class UpgradeLlmCostTrackerCallRollupsProvider")
        expect(migration).to include('add_column TABLE, :provider, :string, null: false, default: ""')
        expect(migration).to include("unless column_exists?(TABLE, :provider)")
        expect(migration).to include("remove_index TABLE, column: OLD_INDEX, unique: true")
        expect(migration).to include("if index_exists?(TABLE, OLD_INDEX, unique: true)")
        expect(migration).to include("add_index TABLE, NEW_INDEX, unique: true")
        expect(migration).to include("unless index_exists?(TABLE, NEW_INDEX, unique: true)")
        expect(migration).to include("OLD_INDEX = %i[period period_start currency].freeze")
        expect(migration).to include("NEW_INDEX = %i[period period_start currency provider].freeze")
        expect(migration).to include("def up")
        expect(migration).to include("def down")
      end
    end

    it "is safe to run twice without writing duplicate migrations" do
      Dir.mktmpdir do |dir|
        2.times do
          LlmCostTracker::Generators::UpgradeCallRollupsProviderGenerator.start([], destination_root: dir)
        end

        migrations = Dir[
          File.join(dir, "db/migrate/*_upgrade_llm_cost_tracker_call_rollups_provider.rb")
        ]
        expect(migrations.size).to eq(1)
      end
    end
  end

  describe "call_rollups generator" do
    it "creates the optional llm_cost_tracker_call_rollups table" do
      Dir.mktmpdir do |dir|
        LlmCostTracker::Generators::CallRollupsGenerator.start([], destination_root: dir)

        migration_path = Dir[
          File.join(dir, "db/migrate/*_create_llm_cost_tracker_call_rollups.rb")
        ].first
        expect(migration_path).not_to be_nil

        migration = File.read(migration_path)
        expect(migration).to include("create_table :llm_cost_tracker_call_rollups")
        expect(migration).to include("t.string :provider")
        expect(migration).to include(
          "add_index :llm_cost_tracker_call_rollups, [:period, :period_start, :currency, :provider], unique: true"
        )
      end
    end
  end

  describe "durable_ingestion generator" do
    it "creates the durable ingestion inbox + leases tables" do
      Dir.mktmpdir do |dir|
        LlmCostTracker::Generators::DurableIngestionGenerator.start([], destination_root: dir)

        migration_path = Dir[
          File.join(dir, "db/migrate/*_create_llm_cost_tracker_durable_ingestion.rb")
        ].first
        expect(migration_path).not_to be_nil

        migration = File.read(migration_path)
        expect(migration).to include("create_table :llm_cost_tracker_ingestion_inbox_entries")
        expect(migration).to include("create_table :llm_cost_tracker_ingestion_leases")
        expect(migration).to include("add_index :llm_cost_tracker_ingestion_inbox_entries, :event_id, unique: true")
        expect(migration).to include("add_index :llm_cost_tracker_ingestion_inbox_entries, [:tracked_at, :attempts]")
        expect(migration).to include("add_index :llm_cost_tracker_ingestion_inbox_entries, [:locked_at, :id]")
        expect(migration).to include("add_index :llm_cost_tracker_ingestion_leases, :name, unique: true")
      end
    end
  end

  describe "schema drift detection" do
    let(:install_migration) { render_migration_template("create_llm_cost_tracker_calls.rb.erb") }

    let(:reconciliation_migration) do
      render_migration_template("create_llm_cost_tracker_reconciliation.rb.erb")
    end

    let(:auto_columns) { %w[id created_at updated_at llm_cost_tracker_call_id] }

    def expect_columns_in(migration, columns)
      missing = columns.reject do |column|
        migration.match?(/[\s,(\[]:#{Regexp.escape(column)}\b/)
      end
      expect(missing).to eq([]),
                         "expected migration to declare #{missing.inspect}; update the generator template when schema columns change"
    end

    it "covers every Calls schema column in the install migration" do
      columns = LlmCostTracker::Ledger::Schema::Calls::CURRENT_SCHEMA_COLUMNS - auto_columns
      expect_columns_in(install_migration, columns)
    end

    it "covers every CallLineItems required column in the install migration" do
      columns = LlmCostTracker::Ledger::Schema::CallLineItems::REQUIRED_COLUMNS - auto_columns
      expect_columns_in(install_migration, columns)
    end

    it "covers every CallTags required column in the install migration" do
      columns = LlmCostTracker::Ledger::Schema::CallTags::REQUIRED_COLUMNS - auto_columns
      expect_columns_in(install_migration, columns)
    end

    let(:call_rollups_migration) { render_migration_template("create_llm_cost_tracker_call_rollups.rb.erb") }

    let(:durable_ingestion_migration) do
      render_migration_template("create_llm_cost_tracker_durable_ingestion.rb.erb")
    end

    it "covers every CallRollups required column in the call_rollups migration" do
      columns = LlmCostTracker::Ledger::Schema::CallRollups::REQUIRED_COLUMNS - auto_columns
      expect_columns_in(call_rollups_migration, columns)
    end

    it "covers every IngestionInboxEntries required column in the durable_ingestion migration" do
      columns = LlmCostTracker::Ledger::Schema::IngestionInboxEntries::REQUIRED_COLUMNS - auto_columns
      expect_columns_in(durable_ingestion_migration, columns)
    end

    it "covers every IngestionLeases required column in the durable_ingestion migration" do
      columns = LlmCostTracker::Ledger::Schema::IngestionLeases::REQUIRED_COLUMNS - auto_columns
      expect_columns_in(durable_ingestion_migration, columns)
    end

    it "covers every ProviderInvoices required column in the reconciliation migration" do
      LlmCostTracker.const_get(:Reconciliation)
      columns = LlmCostTracker::Ledger::Schema::ProviderInvoices::REQUIRED_COLUMNS - auto_columns
      expect_columns_in(reconciliation_migration, columns)
    end

    it "covers every ProviderInvoiceImports required column in the reconciliation migration" do
      LlmCostTracker.const_get(:Reconciliation)
      columns = LlmCostTracker::Ledger::Schema::ProviderInvoiceImports::REQUIRED_COLUMNS - auto_columns
      expect_columns_in(reconciliation_migration, columns)
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
