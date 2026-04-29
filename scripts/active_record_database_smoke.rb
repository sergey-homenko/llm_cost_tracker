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
require "llm_cost_tracker/llm_api_call"
require "llm_cost_tracker/inbox_event"
require "llm_cost_tracker/ingestor_lease"
require "llm_cost_tracker/period_total"

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
    LlmCostTracker::LlmApiCall,
    LlmCostTracker::InboxEvent,
    LlmCostTracker::IngestorLease,
    LlmCostTracker::PeriodTotal
  ].each(&:reset_column_information)
  LlmCostTracker::Storage::ActiveRecordInbox.reset!
  LlmCostTracker::Storage::ActiveRecordStore.reset!
  LlmCostTracker::Storage::ActiveRecordIngestor.reset!
end

def create_schema!
  ActiveRecord::Schema.define do
    create_calls_table!(connection)
    create_period_totals_table!
    create_inbox_events_table!
    create_ingestor_leases_table!
    add_schema_indexes!(connection)
  end
end

def create_calls_table!(database_connection)
  create_table :llm_api_calls, force: true do |t|
    add_call_identity_columns(t)
    add_call_usage_columns(t)
    add_call_cost_columns(t)
    t.integer :latency_ms
    t.boolean :stream, null: false, default: false
    t.string :usage_source
    t.string :provider_response_id
    t.string :pricing_mode
    add_call_tags_column(t, database_connection)
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
  table.integer :input_tokens, null: false, default: 0
  table.integer :output_tokens, null: false, default: 0
  table.integer :total_tokens, null: false, default: 0
  table.integer :cache_read_input_tokens, null: false, default: 0
  table.integer :cache_write_input_tokens, null: false, default: 0
  table.integer :hidden_output_tokens, null: false, default: 0
end

def add_call_cost_columns(table)
  table.decimal :input_cost, precision: 20, scale: 8
  table.decimal :cache_read_input_cost, precision: 20, scale: 8
  table.decimal :cache_write_input_cost, precision: 20, scale: 8
  table.decimal :output_cost, precision: 20, scale: 8
  table.decimal :total_cost, precision: 20, scale: 8
end

def add_call_tags_column(table, database_connection)
  if LlmCostTracker::ActiveRecordAdapter.postgresql?(database_connection)
    table.jsonb :tags, null: false, default: {}
  else
    table.text :tags
  end
end

def create_period_totals_table!
  create_table :llm_cost_tracker_period_totals, force: true do |t|
    t.string :period, null: false
    t.date :period_start, null: false
    t.decimal :total_cost, precision: 20, scale: 8, null: false, default: 0
    t.timestamps
  end
end

def create_inbox_events_table!
  create_table :llm_cost_tracker_inbox_events, force: true do |t|
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

def create_ingestor_leases_table!
  create_table :llm_cost_tracker_ingestor_leases, force: true do |t|
    t.string :name, null: false
    t.string :locked_by
    t.datetime :locked_until
    t.timestamps
  end
end

def add_schema_indexes!(database_connection)
  add_index :llm_api_calls, :event_id, unique: true
  add_index :llm_api_calls, :tracked_at
  add_index :llm_api_calls, %i[provider tracked_at]
  add_index :llm_api_calls, %i[model tracked_at]
  add_index :llm_api_calls, :provider_response_id
  add_index :llm_api_calls, :tags, using: :gin if LlmCostTracker::ActiveRecordAdapter.postgresql?(database_connection)
  add_index :llm_cost_tracker_period_totals, %i[period period_start], unique: true
  add_index :llm_cost_tracker_inbox_events, :event_id, unique: true
  add_index :llm_cost_tracker_inbox_events, :tracked_at
  add_index :llm_cost_tracker_inbox_events, %i[locked_at id]
  add_index :llm_cost_tracker_ingestor_leases, :name, unique: true
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

def track!(provider_response_id:, input_tokens: 100, output_tokens: 200, **tags)
  LlmCostTracker.track(
    provider: "smoke",
    model: "small",
    input_tokens: input_tokens,
    output_tokens: output_tokens,
    provider_response_id: provider_response_id,
    latency_ms: 12,
    **tags
  )
end

def flush!
  assert("flush timed out") { LlmCostTracker.flush!(timeout: 10) }
end

def quarantined_row_count
  LlmCostTracker::InboxEvent.where(
    "attempts >= ?",
    LlmCostTracker::Storage::ActiveRecordInbox::MAX_ATTEMPTS
  ).count
end

begin
  create_database!(adapter, admin, database)
  ActiveRecord::Base.establish_connection(test_config)
  create_schema!
  reset_models!

  assert("PostgreSQL adapter family was not detected") do
    adapter != "postgresql" || LlmCostTracker::ActiveRecordAdapter.postgresql?(ActiveRecord::Base.connection)
  end
  assert("MySQL-family adapter was not detected") do
    adapter != "trilogy" || LlmCostTracker::ActiveRecordAdapter.mysql?(ActiveRecord::Base.connection)
  end

  LlmCostTracker.reset_configuration!
  LlmCostTracker.configure do |config|
    config.storage_backend = :active_record
    config.storage_error_behavior = :raise
    config.unknown_pricing_behavior = :raise
    config.pricing_overrides = {
      "smoke/small" => {
        input: 10.0,
        output: 20.0
      }
    }
  end

  assert("inbox is not enabled on #{adapter} schema") { LlmCostTracker::Storage::ActiveRecordInbox.enabled? }

  rollback_event = nil
  LlmCostTracker::LlmApiCall.transaction do
    rollback_event = track!(provider_response_id: "rollback", feature: "rollback")
    raise ActiveRecord::Rollback
  end
  sleep 0.1
  durable_rows = LlmCostTracker::InboxEvent.where(event_id: rollback_event.event_id).count +
                 LlmCostTracker::LlmApiCall.where(event_id: rollback_event.event_id).count
  assert("event was lost across caller rollback") { durable_rows == 1 }
  flush!
  assert("rollback event did not reach ledger") do
    LlmCostTracker::LlmApiCall.where(event_id: rollback_event.event_id, provider_response_id: "rollback").one?
  end

  pending_event = track!(provider_response_id: "pending", feature: "pending")
  pending_total = LlmCostTracker::Storage::ActiveRecordStore.daily_total(time: Time.now.utc)
  assert("daily total did not include pending or persisted inbox event") do
    pending_total >= pending_event.cost.total_cost.to_f
  end
  flush!

  duplicate_event = track!(provider_response_id: "duplicate", feature: "duplicate")
  flush!
  before_duplicate_total = LlmCostTracker::Storage::ActiveRecordStore.daily_total(time: Time.now.utc)
  LlmCostTracker::Storage::ActiveRecordInbox.save(duplicate_event)
  flush!
  after_duplicate_total = LlmCostTracker::Storage::ActiveRecordStore.daily_total(time: Time.now.utc)
  assert("duplicate inbox row changed rollup total") do
    BigDecimal(after_duplicate_total.to_s) == BigDecimal(before_duplicate_total.to_s)
  end
  assert("duplicate event was inserted twice") do
    LlmCostTracker::LlmApiCall.where(event_id: duplicate_event.event_id).one?
  end

  now = Time.now.utc
  LlmCostTracker::InboxEvent.create!(
    event_id: "poison-#{SecureRandom.hex(4)}",
    total_cost: 1,
    tracked_at: now,
    payload: "{bad-json",
    attempts: LlmCostTracker::Storage::ActiveRecordInbox::MAX_ATTEMPTS - 1,
    created_at: now,
    updated_at: now
  )
  good_event = track!(provider_response_id: "after-poison", feature: "poison")
  flush!
  assert("healthy row behind poison was not persisted") do
    LlmCostTracker::LlmApiCall.where(event_id: good_event.event_id).exists?
  end
  assert("poison row was not quarantined at max attempts") do
    LlmCostTracker::InboxEvent.where(
      "payload = ? AND attempts >= ?",
      "{bad-json",
      LlmCostTracker::Storage::ActiveRecordInbox::MAX_ATTEMPTS
    ).exists?
  end

  LlmCostTracker::Storage::ActiveRecordIngestor.shutdown!(drain: false)
  before_count = LlmCostTracker::LlmApiCall.count
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
  assert("concurrent tracking count mismatch: expected #{expected}, got #{LlmCostTracker::LlmApiCall.count}") do
    LlmCostTracker::LlmApiCall.count == expected
  end
  assert("retryable inbox rows remain after flush") do
    !LlmCostTracker::InboxEvent.where("attempts < ?", LlmCostTracker::Storage::ActiveRecordInbox::MAX_ATTEMPTS).exists?
  end

  puts "#{adapter} smoke passed"
  puts "database=#{database}"
  puts "adapter=#{ActiveRecord::Base.connection.class.name}"
  puts "ledger_rows=#{LlmCostTracker::LlmApiCall.count}"
  puts "quarantined_rows=#{quarantined_row_count}"
  puts "daily_total=#{LlmCostTracker::Storage::ActiveRecordStore.daily_total(time: Time.now.utc)}"
ensure
  begin
    LlmCostTracker.shutdown!(drain: false) if defined?(LlmCostTracker)
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
