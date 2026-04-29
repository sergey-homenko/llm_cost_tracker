# frozen_string_literal: true

require "spec_helper"
require "active_record"
require "tempfile"

RSpec.describe "ActiveRecord durable inbox" do
  before do
    @database = Tempfile.new(["llm-cost-tracker", ".sqlite3"])
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: @database.path, pool: 5)

    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table :llm_api_calls do |t|
        t.string :event_id, null: false
        t.string :provider, null: false
        t.string :model, null: false
        t.integer :input_tokens, null: false, default: 0
        t.integer :output_tokens, null: false, default: 0
        t.integer :total_tokens, null: false, default: 0
        t.integer :cache_read_input_tokens, null: false, default: 0
        t.integer :cache_write_input_tokens, null: false, default: 0
        t.integer :hidden_output_tokens, null: false, default: 0
        t.decimal :input_cost, precision: 20, scale: 8
        t.decimal :cache_read_input_cost, precision: 20, scale: 8
        t.decimal :cache_write_input_cost, precision: 20, scale: 8
        t.decimal :output_cost, precision: 20, scale: 8
        t.decimal :total_cost, precision: 20, scale: 8
        t.integer :latency_ms
        t.boolean :stream, null: false, default: false
        t.string :usage_source
        t.string :provider_response_id
        t.string :pricing_mode
        t.text :tags
        t.datetime :tracked_at, null: false

        t.timestamps
      end

      create_table :llm_cost_tracker_period_totals do |t|
        t.string :period, null: false
        t.date :period_start, null: false
        t.decimal :total_cost, precision: 20, scale: 8, null: false, default: 0

        t.timestamps
      end

      create_table :llm_cost_tracker_inbox_events do |t|
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

      create_table :llm_cost_tracker_ingestor_leases do |t|
        t.string :name, null: false
        t.string :locked_by
        t.datetime :locked_until

        t.timestamps
      end

      add_index :llm_api_calls, :event_id, unique: true
      add_index :llm_cost_tracker_period_totals, %i[period period_start], unique: true
      add_index :llm_cost_tracker_inbox_events, :event_id, unique: true
      add_index :llm_cost_tracker_ingestor_leases, :name, unique: true
    end

    LlmCostTracker::LlmApiCall.reset_column_information if defined?(LlmCostTracker::LlmApiCall)
    LlmCostTracker::PeriodTotal.reset_column_information if defined?(LlmCostTracker::PeriodTotal)
    LlmCostTracker::InboxEvent.reset_column_information if defined?(LlmCostTracker::InboxEvent)
    LlmCostTracker::IngestorLease.reset_column_information if defined?(LlmCostTracker::IngestorLease)
    LlmCostTracker::Storage::ActiveRecordInbox.reset!
    LlmCostTracker::Storage::ActiveRecordStore.reset!

    LlmCostTracker.configure do |config|
      config.storage_backend = :active_record
    end

    allow(LlmCostTracker::Storage::ActiveRecordIngestor).to receive(:ensure_started)
  end

  after do
    LlmCostTracker.shutdown!
    ActiveRecord::Base.connection.disconnect!
    @database.close!
  end

  def llm_api_call_model
    require "llm_cost_tracker/llm_api_call" unless defined?(LlmCostTracker::LlmApiCall)

    LlmCostTracker::LlmApiCall
  end

  def inbox_event_model
    require "llm_cost_tracker/inbox_event" unless defined?(LlmCostTracker::InboxEvent)

    LlmCostTracker::InboxEvent
  end

  def period_total_model
    require "llm_cost_tracker/period_total" unless defined?(LlmCostTracker::PeriodTotal)

    LlmCostTracker::PeriodTotal
  end

  it "captures events into a durable inbox before ingesting them into the ledger" do
    event = LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0,
      feature: "chat"
    )

    expect(inbox_event_model.count).to eq(1)
    expect(llm_api_call_model.count).to eq(0)
    expect(inbox_event_model.first.event_id).to eq(event.event_id)

    expect(LlmCostTracker.flush!).to be true

    call = llm_api_call_model.first
    expect(inbox_event_model.count).to eq(0)
    expect(call.event_id).to eq(event.event_id)
    expect(call.total_cost.to_f).to eq(0.0025)
    expect(call.parsed_tags).to include("feature" => "chat")
  end

  it "includes pending inbox costs in period totals before ingesting" do
    allow(Time).to receive(:now).and_return(Time.utc(2026, 4, 18, 12))

    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )

    expect(period_total_model.count).to eq(0)
    expect(LlmCostTracker::Storage::ActiveRecordStore.daily_total(time: Time.utc(2026, 4, 18, 23))).to eq(0.0025)
    expect(LlmCostTracker::Storage::ActiveRecordStore.monthly_total(time: Time.utc(2026, 4, 30, 23))).to eq(0.0025)

    LlmCostTracker.flush!

    expect(inbox_event_model.count).to eq(0)
    expect(period_total_model.find_by!(period: "day", period_start: Date.new(2026, 4, 18)).total_cost.to_f)
      .to eq(0.0025)
    expect(LlmCostTracker::Storage::ActiveRecordStore.daily_total(time: Time.utc(2026, 4, 18, 23))).to eq(0.0025)
  end

  it "reads stored and pending budget totals in one database statement" do
    time = Time.utc(2026, 4, 18, 12)
    period_total_model.create!(
      period: "day",
      period_start: Date.new(2026, 4, 18),
      total_cost: 1.25
    )
    inbox_event_model.create!(
      event_id: "pending-event",
      total_cost: 2.5,
      tracked_at: time,
      payload: "{}"
    )
    sqls = []
    allow(llm_api_call_model.connection).to receive(:select_all).and_wrap_original do |method, *args, **kwargs|
      sql_text = args.first.to_s
      sqls << sql_text if sql_text.include?("llm_cost_tracker_inbox_events")
      method.call(*args, **kwargs)
    end

    expect(LlmCostTracker::Storage::ActiveRecordStore.daily_total(time: time)).to eq(3.75)
    expect(sqls.size).to eq(1)
    expect(sqls.first).to include("llm_cost_tracker_period_totals")
    expect(sqls.first).to include("llm_cost_tracker_inbox_events")
  end

  it "ingests unknown-cost events without adding pending budget totals" do
    LlmCostTracker.configure do |config|
      config.storage_backend = :active_record
      config.unknown_pricing_behavior = :ignore
    end

    event = LlmCostTracker.track(
      provider: :openai,
      model: "unknown-model",
      input_tokens: 1_000,
      output_tokens: 0
    )

    expect(inbox_event_model.first.total_cost).to be_nil
    expect(LlmCostTracker::Storage::ActiveRecordStore.daily_total(time: event.tracked_at)).to eq(0.0)

    LlmCostTracker.flush!

    expect(llm_api_call_model.find_by!(event_id: event.event_id).total_cost).to be_nil
  end

  it "does not double-count a retried inbox event that already reached the ledger" do
    event = LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )
    row = inbox_event_model.first
    parsed = LlmCostTracker::Storage::ActiveRecordInbox.event_from_row(row)

    LlmCostTracker::LlmApiCall.transaction do
      LlmCostTracker::Storage::ActiveRecordStore.insert_many([parsed])
    end
    LlmCostTracker.flush!

    expect(llm_api_call_model.where(event_id: event.event_id).count).to eq(1)
    expect(period_total_model.find_by!(period: "day", period_start: Date.current).total_cost.to_f).to eq(0.0025)
    expect(inbox_event_model.count).to eq(0)
  end

  it "does not increment rollups when a concurrent duplicate insert wins the race" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )
    row = inbox_event_model.first
    parsed = LlmCostTracker::Storage::ActiveRecordInbox.event_from_row(row)
    allow(llm_api_call_model).to receive(:insert_all!).and_raise(ActiveRecord::RecordNotUnique)

    expect do
      LlmCostTracker::Storage::ActiveRecordStore.insert_many([parsed])
    end.to raise_error(ActiveRecord::RecordNotUnique)
    expect(period_total_model.count).to eq(0)

    inbox_event_model.delete_all
  end

  it "allows one ingestor lease holder until the lease expires" do
    first = LlmCostTracker::Storage::ActiveRecordIngestorLease.new(identity: "worker-a", seconds: 10)
    second = LlmCostTracker::Storage::ActiveRecordIngestorLease.new(identity: "worker-b", seconds: 10)

    expect(first.acquire).to be true
    expect(first.acquire).to be true
    expect(second.acquire).to be false

    LlmCostTracker::IngestorLease.find_by!(name: "default").update!(locked_until: Time.now.utc - 1)

    expect(second.acquire).to be true
  end

  it "does not ingest while another worker owns the leader lease" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )
    LlmCostTracker::IngestorLease.create!(
      name: "default",
      locked_by: "worker-a",
      locked_until: Time.now.utc + 30
    )

    expect(LlmCostTracker::Storage::ActiveRecordIngestor.ingest_once).to eq(0)
    expect(inbox_event_model.count).to eq(1)

    LlmCostTracker::IngestorLease.find_by!(name: "default").update!(locked_until: Time.now.utc - 1)

    expect(LlmCostTracker::Storage::ActiveRecordIngestor.ingest_once).to eq(1)
    expect(inbox_event_model.count).to eq(0)
  end

  it "marks failed batches for retry" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )
    allow(LlmCostTracker::Storage::ActiveRecordStore).to receive(:insert_many).and_raise("write failed")
    allow(LlmCostTracker::Logging).to receive(:warn)

    expect(LlmCostTracker::Storage::ActiveRecordIngestor.ingest_once(require_lease: false)).to eq(0)

    row = inbox_event_model.first
    expect(row.locked_at).not_to be_nil
    expect(row.locked_by).to be_nil
    expect(row.last_error).to include("write failed")

    inbox_event_model.delete_all
  end

  it "quarantines invalid inbox rows without blocking valid rows behind them" do
    now = Time.utc(2026, 4, 18, 12)
    inbox_event_model.create!(
      event_id: "bad-event",
      total_cost: 1.0,
      tracked_at: now,
      payload: "{",
      attempts: LlmCostTracker::Storage::ActiveRecordInbox::MAX_ATTEMPTS - 1
    )
    event = LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )

    expect(LlmCostTracker::Storage::ActiveRecordIngestor.ingest_once(require_lease: false)).to eq(2)

    bad_row = inbox_event_model.find_by!(event_id: "bad-event")
    expect(bad_row.attempts).to eq(LlmCostTracker::Storage::ActiveRecordInbox::MAX_ATTEMPTS)
    expect(bad_row.last_error).to include("JSON")
    expect(llm_api_call_model.find_by!(event_id: event.event_id)).to be_present
    expect(LlmCostTracker.flush!(timeout: 0.01)).to be true
    expect(inbox_event_model.where(event_id: "bad-event")).to exist

    inbox_event_model.delete_all
  end

  it "excludes quarantined inbox rows from pending budget totals" do
    time = Time.utc(2026, 4, 18, 12)
    inbox_event_model.create!(
      event_id: "bad-event",
      total_cost: 1.0,
      tracked_at: time,
      payload: "{",
      attempts: LlmCostTracker::Storage::ActiveRecordInbox::MAX_ATTEMPTS
    )

    expect(LlmCostTracker::Storage::ActiveRecordStore.daily_total(time: time)).to eq(0.0)
  end

  it "reports quarantined inbox rows in doctor output" do
    inbox_event_model.create!(
      event_id: "bad-event",
      total_cost: 1.0,
      tracked_at: Time.utc(2026, 4, 18, 12),
      payload: "{",
      attempts: LlmCostTracker::Storage::ActiveRecordInbox::MAX_ATTEMPTS
    )

    check = LlmCostTracker::Doctor.call.find { |item| item.name == "durable ingestion" }

    expect(check).to have_attributes(status: :warn, message: include("quarantined"))
  end

  it "reports stale pending inbox rows in doctor output" do
    time = Time.now.utc - 120
    inbox_event_model.create!(
      event_id: "pending-event",
      total_cost: 1.0,
      tracked_at: time,
      payload: "{}",
      created_at: time,
      updated_at: time
    )

    check = LlmCostTracker::Doctor.call.find { |item| item.name == "durable ingestion" }

    expect(check).to have_attributes(status: :warn, message: include("pending"))
  end

  it "times out flush when every row is leased by another worker" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )
    inbox_event_model.update_all(locked_at: Time.now.utc, locked_by: "worker-a")

    expect(LlmCostTracker.flush!(timeout: 0.01)).to be false

    inbox_event_model.delete_all
  end

  it "returns false when flush reaches the timeout during an ingest attempt" do
    ingestor = LlmCostTracker::Storage::ActiveRecordIngestor
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )
    allow(ingestor).to receive(:ingest_once) do
      sleep 0.02
      0
    end

    expect(ingestor.flush!(timeout: 0.001)).to be false
  ensure
    inbox_event_model.delete_all
  end

  it "starts and stops the ingestor thread lazily" do
    allow(LlmCostTracker::Storage::ActiveRecordIngestor).to receive(:ensure_started).and_wrap_original(&:call)
    llm_api_call_model
    LlmCostTracker::Storage::ActiveRecordInbox.reset!

    LlmCostTracker::Storage::ActiveRecordIngestor.ensure_started

    thread = LlmCostTracker::Storage::ActiveRecordIngestor.instance_variable_get(:@thread)
    expect(thread).to be_alive
    expect(LlmCostTracker.shutdown!).to be true
  end

  it "does not wake a running ingestor thread on every capture" do
    ingestor = LlmCostTracker::Storage::ActiveRecordIngestor
    thread = instance_double(Thread, alive?: true)
    ingestor.instance_variable_set(:@pid, Process.pid)
    ingestor.instance_variable_set(:@thread, thread)

    expect(thread).not_to receive(:wakeup)

    ingestor.ensure_started
  ensure
    ingestor.instance_variable_set(:@thread, nil)
  end

  it "does not let an old ingestor generation resume after reset" do
    ingestor = LlmCostTracker::Storage::ActiveRecordIngestor
    old_generation = ingestor.send(:next_generation)
    ingestor.send(:next_generation)
    ingestor.instance_variable_set(:@stop_requested, false)
    allow(ingestor).to receive(:claimable_events?).and_return(true)
    allow(ingestor).to receive(:ingest_once)

    ingestor.send(:run, old_generation)

    expect(ingestor).not_to have_received(:claimable_events?)
    expect(ingestor).not_to have_received(:ingest_once)
  end

  it "verifies and cleans up capture through the durable inbox" do
    checks = LlmCostTracker::Storage::ActiveRecordBackend.verify
    check = checks.find { |item| item.name == "active_record capture" }

    expect(check).to have_attributes(status: :ok, message: include("durable inbox"))
    expect(llm_api_call_model.where("provider_response_id LIKE ?", "lct_verify_%")).to be_empty
    expect(inbox_event_model.count).to eq(0)
    expect(period_total_model.sum(:total_cost).to_f).to eq(0.0)
  end

  it "reports a failed durable inbox verification when flush does not persist the row" do
    allow(LlmCostTracker).to receive(:flush!).and_return(false)

    checks = LlmCostTracker::Storage::ActiveRecordBackend.verify
    check = checks.find { |item| item.name == "active_record capture" }

    expect(check).to have_attributes(status: :error, message: include("persisted row"))
    expect(inbox_event_model.count).to eq(0)
  end

  it "reports a missing ActiveRecord table during verification" do
    allow(llm_api_call_model).to receive(:table_exists?).and_return(false)

    checks = LlmCostTracker::Storage::ActiveRecordBackend.verify

    expect(checks.first).to have_attributes(status: :error, message: include("llm_api_calls table is missing"))
  end

  it "reports unexpected ActiveRecord verification failures" do
    allow(llm_api_call_model).to receive(:table_exists?).and_raise("schema failed")

    checks = LlmCostTracker::Storage::ActiveRecordBackend.verify

    expect(checks.first).to have_attributes(status: :error, message: include("schema failed"))
  end

  it "avoids a second SQLite writer connection inside caller transactions" do
    llm_api_call_model.transaction do
      LlmCostTracker.track(
        provider: :openai,
        model: "gpt-4o",
        input_tokens: 1_000,
        output_tokens: 0
      )
      raise ActiveRecord::Rollback
    end

    expect(llm_api_call_model.count).to eq(0)
    expect(inbox_event_model.count).to eq(0)
  end

  it "can capture through a separate connection when the caller has an open transaction" do
    connection = llm_api_call_model.connection
    allow(connection).to receive(:transaction_open?).and_return(true)
    allow(LlmCostTracker::Storage::ActiveRecordInbox).to receive(:sqlite_database?).and_return(false)

    event = LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )

    expect(inbox_event_model.find_by!(event_id: event.event_id)).to be_present
  end

  it "fails honestly when no separate connection is available inside a caller transaction" do
    connection = llm_api_call_model.connection
    allow(connection).to receive(:transaction_open?).and_return(true)
    allow(LlmCostTracker::Storage::ActiveRecordInbox).to receive(:sqlite_database?).and_return(false)
    allow(LlmCostTracker::Storage::ActiveRecordInbox)
      .to receive(:insert_with_separate_connection)
      .and_raise(ActiveRecord::ConnectionTimeoutError)
    allow(LlmCostTracker::Logging).to receive(:warn)

    event = LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )

    expect(inbox_event_model.where(event_id: event.event_id)).to be_empty
    expect(LlmCostTracker::Logging).to have_received(:warn).with(include("could not checkout"))
  end

  it "returns false when shutdown cannot flush cleanly" do
    allow(LlmCostTracker::Storage::ActiveRecordIngestor).to receive(:flush!).and_raise("flush failed")
    allow(LlmCostTracker::Logging).to receive(:warn)

    expect(LlmCostTracker::Storage::ActiveRecordIngestor.shutdown!(timeout: 0.01)).to be false
  end

  it "passes shutdown timeout through the public API" do
    allow(LlmCostTracker::Storage::ActiveRecordIngestor).to receive(:shutdown!).and_return(true)
    expect(LlmCostTracker::Storage::ActiveRecordIngestor)
      .to receive(:shutdown!)
      .with(timeout: 0.01, drain: true)
      .and_return(true)

    expect(LlmCostTracker.shutdown!(timeout: 0.01)).to be true
  end

  it "can stop the ingestor without draining durable rows" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )
    flush_calls = 0
    allow(LlmCostTracker::Storage::ActiveRecordIngestor).to receive(:flush!) { flush_calls += 1 }

    expect(LlmCostTracker::Storage::ActiveRecordIngestor.shutdown!(timeout: 0.01, drain: false)).to be true
    expect(flush_calls).to eq(0)
    expect(inbox_event_model.count).to eq(1)
  end

  it "uses the leader lease when shutdown drains" do
    flush_calls = []
    allow(LlmCostTracker::Storage::ActiveRecordIngestor).to receive(:flush!) do |**kwargs|
      flush_calls << kwargs
      true
    end

    expect(LlmCostTracker::Storage::ActiveRecordIngestor.shutdown!(timeout: 0.01)).to be true
    expect(flush_calls).to eq([{ timeout: 0.01, require_lease: true }])
  end

  it "keeps the ingestor loop alive after transient failures" do
    ingestor = LlmCostTracker::Storage::ActiveRecordIngestor
    calls = 0
    generation = ingestor.send(:next_generation)
    allow(ingestor).to receive(:sleep)
    allow(LlmCostTracker::Logging).to receive(:warn)
    allow(ActiveRecord::Base.connection_handler).to receive(:clear_active_connections!)
    allow(ingestor).to receive(:claimable_events?).and_return(true)
    allow(ingestor).to receive(:ingest_once) do
      calls += 1
      ingestor.instance_variable_set(:@stop_requested, true)
      raise "temporary failure"
    end

    ingestor.instance_variable_set(:@stop_requested, false)
    ingestor.send(:run, generation)

    expect(calls).to eq(1)
    expect(ActiveRecord::Base.connection_handler).to have_received(:clear_active_connections!).at_least(:once)
  end

  it "resets the idle interval after a processed batch" do
    ingestor = LlmCostTracker::Storage::ActiveRecordIngestor
    generation = ingestor.send(:next_generation)
    allow(ingestor).to receive(:claimable_events?).and_return(true)
    allow(ingestor).to receive(:ingest_once) do
      ingestor.instance_variable_set(:@stop_requested, true)
      1
    end

    ingestor.instance_variable_set(:@stop_requested, false)
    ingestor.send(:run, generation)

    expect(ingestor).to have_received(:ingest_once)
  end

  it "ignores connection cleanup failures" do
    allow(ActiveRecord::Base.connection_handler).to receive(:clear_active_connections!).and_raise("cleanup failed")

    expect do
      LlmCostTracker::Storage::ActiveRecordConnectionCleanup.release!
    end.not_to raise_error
  end

  it "does not acquire a leader lease while the inbox is empty" do
    ingestor = LlmCostTracker::Storage::ActiveRecordIngestor
    generation = ingestor.send(:next_generation)
    allow(ingestor).to receive(:sleep) { ingestor.instance_variable_set(:@stop_requested, true) }
    allow(ingestor).to receive(:claimable_events?).and_return(false)
    allow(ingestor).to receive(:acquire_lease)

    ingestor.instance_variable_set(:@stop_requested, false)
    ingestor.send(:run, generation)

    expect(ingestor).not_to have_received(:acquire_lease)
  end

  it "wraps background ingestion work with the Rails executor when available" do
    ingestor = LlmCostTracker::Storage::ActiveRecordIngestor
    generation = ingestor.send(:next_generation)
    executor = double("executor")
    application = double("application", executor: executor)
    stub_const("Rails", double("rails", application: application))
    allow(executor).to receive(:wrap) { |&block| block.call }
    allow(ingestor).to receive(:sleep) { ingestor.instance_variable_set(:@stop_requested, true) }
    allow(ingestor).to receive(:claimable_events?).and_return(false)

    ingestor.instance_variable_set(:@stop_requested, false)
    ingestor.send(:run, generation)

    expect(executor).to have_received(:wrap)
  end

  it "keeps running when Rails executor lookup fails" do
    ingestor = LlmCostTracker::Storage::ActiveRecordIngestor
    rails = double("rails")
    stub_const("Rails", rails)
    allow(rails).to receive(:respond_to?).with(:application).and_return(true)
    allow(rails).to receive(:application).and_raise("executor failed")
    yielded = false

    ingestor.send(:executor_wrap) { yielded = true }

    expect(yielded).to be true
  end

  it "ignores wakeup races for threads that already stopped" do
    thread = double("thread", alive?: true)
    allow(thread).to receive(:wakeup).and_raise(ThreadError)

    expect do
      LlmCostTracker::Storage::ActiveRecordIngestor.send(:wake_thread, thread)
    end.not_to raise_error
  end

  it "ignores failures while marking failed rows" do
    allow(inbox_event_model).to receive(:where).and_raise("write failed")
    batch = LlmCostTracker::Storage::ActiveRecordInboxBatch.new(identity: "test")

    expect do
      batch.mark_failed(
        [instance_double(inbox_event_model, id: 1)],
        RuntimeError.new("boom")
      )
    end.not_to raise_error
  end
end
