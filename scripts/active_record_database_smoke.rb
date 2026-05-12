# frozen_string_literal: true

require "active_record"
require "bigdecimal"
require "json"
require "securerandom"
require "time"

adapter = ENV.fetch("LCT_SMOKE_ADAPTER")

case adapter
when "postgresql"
  require "pg"
when "trilogy"
  require "active_record/connection_adapters/trilogy_adapter"
  require "trilogy"
else
  abort "Unsupported LCT_SMOKE_ADAPTER=#{adapter.inspect}"
end

require "llm_cost_tracker"
require "llm_cost_tracker/ledger"
require_relative "../app/models/llm_cost_tracker/call"
require_relative "../app/models/llm_cost_tracker/call_line_item"
require_relative "../app/models/llm_cost_tracker/call_tag"
require_relative "../app/models/llm_cost_tracker/call_rollup"
require_relative "../app/models/llm_cost_tracker/ingestion/inbox_entry"
require_relative "../app/models/llm_cost_tracker/ingestion/lease"

admin = {
  adapter: adapter,
  host: ENV.fetch("LCT_SMOKE_HOST", "127.0.0.1"),
  port: Integer(ENV.fetch("LCT_SMOKE_PORT")),
  username: ENV.fetch("LCT_SMOKE_USERNAME"),
  password: ENV.fetch("LCT_SMOKE_PASSWORD"),
  database: ENV.fetch("LCT_SMOKE_ADMIN_DATABASE"),
  pool: 20,
  checkout_timeout: 5
}

database = "llm_cost_tracker_#{adapter}_smoke_#{Process.pid}_#{SecureRandom.hex(4)}"
test_config = admin.merge(database: database)

class SmokeFailure < StandardError; end

def assert(message)
  raise SmokeFailure, message unless yield
end

def clear_connections!
  handler = ActiveRecord::Base.connection_handler
  if handler.respond_to?(:clear_all_connections!)
    handler.clear_all_connections!
  elsif ActiveRecord::Base.respond_to?(:clear_all_connections!)
    ActiveRecord::Base.clear_all_connections!
  else
    ActiveRecord::Base.connection_pool&.disconnect!
  end
end

def reset_models!
  [
    LlmCostTracker::Call,
    LlmCostTracker::CallLineItem,
    LlmCostTracker::CallTag,
    LlmCostTracker::Ingestion::InboxEntry,
    LlmCostTracker::Ingestion::Lease,
    LlmCostTracker::CallRollup
  ].each(&:reset_column_information)
  LlmCostTracker::Ingestion::Worker.reset!
end

def create_schema!
  ActiveRecord::Schema.define do
    create_calls_table!(connection)
    create_call_line_items_table!(connection)
    create_call_tags_table!
    create_call_rollups_table!
    create_provider_invoices_table!(connection)
    create_provider_invoice_imports_table!
    create_ingestion_inbox_entries_table!
    create_ingestion_leases_table!
    add_schema_indexes!(connection)
  end
end

def create_provider_invoices_table!(database_connection)
  postgresql = LlmCostTracker::Ledger::Schema::Adapter.postgresql?(database_connection)
  create_table :llm_cost_tracker_provider_invoices, force: true do |t|
    t.string :source, null: false
    t.date :period_start, null: false
    t.date :period_end, null: false
    t.string :external_id, null: false
    t.decimal :billed_amount, precision: 20, scale: 8
    t.string :currency, null: false, default: "USD"
    if postgresql
      t.jsonb :metadata, null: false, default: {}
    else
      t.json :metadata, null: false
    end
    t.datetime :imported_at, null: false
    t.timestamps
  end
end

def create_provider_invoice_imports_table!
  create_table :llm_cost_tracker_provider_invoice_imports, force: true do |t|
    t.string :source, null: false
    t.string :cursor
    t.date :window_start
    t.date :window_end
    t.string :state, null: false
    t.text :last_error
    t.integer :rows_imported, null: false, default: 0
    t.datetime :started_at, null: false
    t.datetime :finished_at
    t.timestamps
  end
end

def create_calls_table!(database_connection)
  create_table :llm_cost_tracker_calls, force: true do |t|
    add_call_identity_columns(t)
    add_call_usage_columns(t)
    add_call_cost_columns(t)
    t.integer :latency_ms
    t.boolean :stream, null: false, default: false
    t.string :usage_source
    t.string :provider_response_id
    t.string :provider_project_id
    t.string :provider_api_key_id
    t.string :provider_workspace_id
    t.boolean :batch, null: false, default: false
    t.string :pricing_mode
    t.string :cost_status
    add_call_pricing_snapshot_column(t, database_connection)
    t.datetime :tracked_at, null: false
    t.timestamps
  end
end

def add_call_identity_columns(table)
  table.string :event_id, null: false
  table.string :provider, null: false
  table.string :model, null: false
end

def add_call_usage_columns(table)
  LlmCostTracker::TokenUsage.members.each do |column|
    table.integer column, null: false, default: 0
  end
end

def add_call_cost_columns(table)
  table.decimal :total_cost, precision: 20, scale: 8
end

def add_call_pricing_snapshot_column(table, database_connection)
  if LlmCostTracker::Ledger::Schema::Adapter.postgresql?(database_connection)
    table.jsonb :pricing_snapshot
  elsif LlmCostTracker::Ledger::Schema::Adapter.mysql?(database_connection)
    table.json :pricing_snapshot
  else
    LlmCostTracker::Ledger::Schema::Adapter.ensure_supported!(database_connection)
  end
end

def create_call_line_items_table!(database_connection)
  create_table :llm_cost_tracker_call_line_items, force: true do |t|
    add_call_line_item_columns(t)
    add_call_line_item_pricing_columns(t)
    add_call_line_item_details_column(t, database_connection)
    t.datetime :created_at, null: false
  end
end

def add_call_line_item_columns(table)
  table.references :llm_cost_tracker_call,
                   null: false,
                   index: false,
                   foreign_key: { to_table: :llm_cost_tracker_calls, on_delete: :cascade }
  table.integer :position, null: false, default: 0, limit: 2
  table.string :kind, null: false
  table.string :direction, null: false
  table.string :modality, null: false
  table.string :cache_state, null: false, default: "none"
  table.decimal :quantity, precision: 30, scale: 10, null: false
  table.string :unit, null: false
end

def add_call_line_item_pricing_columns(table)
  table.decimal :rate_amount, precision: 20, scale: 8
  table.decimal :rate_quantity, precision: 30, scale: 10, null: false, default: 1
  table.decimal :cost, precision: 20, scale: 8
  table.string :currency, null: false, default: "USD"
  table.string :cost_status, null: false, default: LlmCostTracker::Billing::CostStatus::UNKNOWN
  table.string :pricing_basis
  table.string :price_key
  table.string :price_source
  table.string :price_source_version
  table.string :provider_field
  table.string :provider_item_id
end

def add_call_line_item_details_column(table, database_connection)
  if LlmCostTracker::Ledger::Schema::Adapter.postgresql?(database_connection)
    table.jsonb :details, null: false, default: {}
  elsif LlmCostTracker::Ledger::Schema::Adapter.mysql?(database_connection)
    table.json :details, null: false
  else
    LlmCostTracker::Ledger::Schema::Adapter.ensure_supported!(database_connection)
  end
end

def create_call_tags_table!
  create_table :llm_cost_tracker_call_tags, force: true do |t|
    t.references :llm_cost_tracker_call,
                 null: false,
                 index: false,
                 foreign_key: { to_table: :llm_cost_tracker_calls, on_delete: :cascade }
    t.string :key, null: false
    t.text :value, null: false
  end
end

def create_call_rollups_table!
  create_table :llm_cost_tracker_call_rollups, force: true do |t|
    t.string :period, null: false
    t.date :period_start, null: false
    t.string :currency, null: false, default: "USD"
    t.string :provider, null: false, default: ""
    t.decimal :total_cost, precision: 20, scale: 8, null: false, default: 0
    t.timestamps
  end
end

def create_ingestion_inbox_entries_table!
  create_table :llm_cost_tracker_ingestion_inbox_entries, force: true do |t|
    t.string :event_id, null: false
    t.decimal :total_cost, precision: 20, scale: 8
    t.datetime :tracked_at, null: false
    t.text :payload, null: false
    t.datetime :locked_at
    t.string :locked_by
    t.integer :attempts, null: false, default: 0
    t.text :last_error
    t.timestamps
  end
end

def create_ingestion_leases_table!
  create_table :llm_cost_tracker_ingestion_leases, force: true do |t|
    t.string :name, null: false
    t.string :locked_by
    t.datetime :locked_until
    t.timestamps
  end
end

def add_schema_indexes!(database_connection)
  add_index :llm_cost_tracker_calls, :event_id, unique: true
  add_index :llm_cost_tracker_calls, :tracked_at
  add_index :llm_cost_tracker_calls, %i[provider tracked_at]
  add_index :llm_cost_tracker_calls, %i[model tracked_at]
  add_index :llm_cost_tracker_calls, :cost_status
  add_index :llm_cost_tracker_calls, :provider_response_id
  add_index :llm_cost_tracker_call_line_items, %i[llm_cost_tracker_call_id position]
  add_index :llm_cost_tracker_call_tags, :llm_cost_tracker_call_id
  if LlmCostTracker::Ledger::Schema::Adapter.postgresql?(database_connection)
    add_index :llm_cost_tracker_call_tags, %i[key value]
  else
    add_index :llm_cost_tracker_call_tags, %i[key value], length: { value: 191 }
  end
  add_index :llm_cost_tracker_call_rollups, %i[period period_start currency provider], unique: true
  add_index :llm_cost_tracker_ingestion_inbox_entries, :event_id, unique: true
  add_index :llm_cost_tracker_ingestion_inbox_entries, %i[tracked_at attempts]
  add_index :llm_cost_tracker_ingestion_inbox_entries, %i[locked_at id]
  add_index :llm_cost_tracker_ingestion_leases, :name, unique: true
  add_index :llm_cost_tracker_provider_invoices, :external_id, unique: true
  add_index :llm_cost_tracker_provider_invoices, %i[source currency period_start]
  add_index :llm_cost_tracker_provider_invoice_imports, %i[source started_at]
end

def create_database!(adapter, admin, database)
  ActiveRecord::Base.establish_connection(admin)
  if adapter == "postgresql"
    ActiveRecord::Base.connection.create_database(database)
  else
    ActiveRecord::Base.connection.execute(
      "CREATE DATABASE `#{database}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
    )
  end
  clear_connections!
end

def drop_database!(adapter, admin, database)
  ActiveRecord::Base.establish_connection(admin)
  if adapter == "postgresql"
    ActiveRecord::Base.connection.drop_database(database)
  else
    ActiveRecord::Base.connection.execute("DROP DATABASE IF EXISTS `#{database}`")
  end
end

def track!(provider_response_id:, tokens: { input: 100, output: 200 }, **tags)
  LlmCostTracker.track(
    provider: "smoke",
    model: "small",
    tokens: tokens,
    provider_response_id: provider_response_id,
    latency_ms: 12,
    tags: tags
  )
end

def flush!
  assert("flush timed out") { LlmCostTracker::Ingestion::Worker.flush!(timeout: 10) }
end

def quarantined_row_count
  LlmCostTracker::Ingestion::InboxEntry.where(
    "attempts >= ?",
    LlmCostTracker::Ingestion::InboxEntry::MAX_ATTEMPTS_BEFORE_QUARANTINE
  ).count
end

begin
  create_database!(adapter, admin, database)
  ActiveRecord::Base.establish_connection(test_config)
  create_schema!
  reset_models!

  assert("PostgreSQL adapter family was not detected") do
    adapter != "postgresql" || LlmCostTracker::Ledger::Schema::Adapter.postgresql?(ActiveRecord::Base.connection)
  end
  assert("MySQL-family adapter was not detected") do
    adapter != "trilogy" || LlmCostTracker::Ledger::Schema::Adapter.mysql?(ActiveRecord::Base.connection)
  end

  LlmCostTracker.reset_configuration!
  LlmCostTracker.configure do |config|
    config.durable_ingestion = true
    config.cache_rollups = true
    config.unknown_pricing_behavior = :raise
    config.pricing_overrides = {
      "smoke/small" => {
        input: 10.0,
        output: 20.0
      }
    }
  end

  rollback_event = nil
  LlmCostTracker::Call.transaction do
    rollback_event = track!(provider_response_id: "rollback", feature: "rollback")
    raise ActiveRecord::Rollback
  end
  sleep 0.1
  durable_rows = LlmCostTracker::Ingestion::InboxEntry.where(event_id: rollback_event.event_id).count +
                 LlmCostTracker::Call.where(event_id: rollback_event.event_id).count
  assert("event was lost across caller rollback") { durable_rows == 1 }
  flush!
  assert("rollback event did not reach ledger") do
    LlmCostTracker::Call.where(event_id: rollback_event.event_id, provider_response_id: "rollback").one?
  end

  pending_event = track!(provider_response_id: "pending", feature: "pending")
  pending_total = LlmCostTracker::Ledger::Period::Totals
                  .call(%i[day], time: Time.now.utc)
                  .fetch(:day)
  assert("daily total did not include pending or persisted inbox entry") do
    pending_total >= pending_event.total_cost.to_f
  end
  flush!

  duplicate_event = track!(provider_response_id: "duplicate", feature: "duplicate")
  flush!
  before_duplicate_total = LlmCostTracker::Ledger::Period::Totals
                           .call(%i[day], time: Time.now.utc)
                           .fetch(:day)
  LlmCostTracker::Ingestion::Inbox.save(duplicate_event)
  flush!
  after_duplicate_total = LlmCostTracker::Ledger::Period::Totals
                          .call(%i[day], time: Time.now.utc)
                          .fetch(:day)
  assert("duplicate inbox entry changed rollup total") do
    BigDecimal(after_duplicate_total.to_s) == BigDecimal(before_duplicate_total.to_s)
  end
  assert("duplicate event was inserted twice") do
    LlmCostTracker::Call.where(event_id: duplicate_event.event_id).one?
  end

  now = Time.now.utc
  LlmCostTracker::Ingestion::InboxEntry.create!(
    event_id: "poison-#{SecureRandom.hex(4)}",
    total_cost: 1,
    tracked_at: now,
    payload: "{bad-json",
    attempts: LlmCostTracker::Ingestion::InboxEntry::MAX_ATTEMPTS_BEFORE_QUARANTINE - 1,
    created_at: now,
    updated_at: now
  )
  good_event = track!(provider_response_id: "after-poison", feature: "poison")
  flush!
  assert("healthy row behind poison was not persisted") do
    LlmCostTracker::Call.where(event_id: good_event.event_id).exists?
  end
  assert("poison row was not quarantined at max attempts") do
    LlmCostTracker::Ingestion::InboxEntry.where(
      "payload = ? AND attempts >= ?",
      "{bad-json",
      LlmCostTracker::Ingestion::InboxEntry::MAX_ATTEMPTS_BEFORE_QUARANTINE
    ).exists?
  end

  LlmCostTracker::Ingestion::Worker.shutdown!(drain: false)
  before_count = LlmCostTracker::Call.count
  thread_count = 8
  per_thread = 10
  threads = thread_count.times.map do |thread_index|
    Thread.new do
      per_thread.times do |event_index|
        ActiveRecord::Base.connection_pool.with_connection do
          track!(
            provider_response_id: "concurrent-#{thread_index}-#{event_index}",
            worker: thread_index,
            index: event_index
          )
        end
      end
    end
  end
  threads.each(&:join)
  flush!
  expected = before_count + (thread_count * per_thread)
  assert("concurrent tracking count mismatch: expected #{expected}, got #{LlmCostTracker::Call.count}") do
    LlmCostTracker::Call.count == expected
  end
  assert("retryable inbox entries remain after flush") do
    !LlmCostTracker::Ingestion::InboxEntry.where("attempts < ?", LlmCostTracker::Ingestion::InboxEntry::MAX_ATTEMPTS_BEFORE_QUARANTINE).exists?
  end

  daily_total = LlmCostTracker::Ledger::Period::Totals
                .call(%i[day], time: Time.now.utc)
                .fetch(:day)

  puts "#{adapter} smoke passed"
  puts "database=#{database}"
  puts "adapter=#{ActiveRecord::Base.connection.class.name}"
  puts "ledger_rows=#{LlmCostTracker::Call.count}"
  puts "quarantined_rows=#{quarantined_row_count}"
  puts "daily_total=#{daily_total}"
ensure
  begin
    LlmCostTracker::Ingestion::Worker.shutdown!(drain: false) if defined?(LlmCostTracker)
  rescue StandardError
    nil
  end
  begin
    clear_connections!
  rescue StandardError
    nil
  end
  begin
    drop_database!(adapter, admin, database) if database
  rescue StandardError => e
    warn "cleanup failed: #{e.class}: #{e.message}"
  ensure
    begin
      clear_connections!
    rescue StandardError
      nil
    end
  end
end
