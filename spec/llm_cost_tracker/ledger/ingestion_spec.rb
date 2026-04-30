# frozen_string_literal: true

require "spec_helper"
require "active_record"

RSpec.describe "ActiveRecord durable inbox" do
  before do
    establish_database_connection!

    ActiveRecord::Schema.verbose = false
    tags_column = method(:add_tags_column)
    ActiveRecord::Schema.define do
      create_table :llm_api_calls, force: true do |t|
        t.string :event_id, null: false
        t.string :provider, null: false
        t.string :model, null: false
        t.integer :input_tokens, null: false, default: 0
        t.integer :output_tokens, null: false, default: 0
        t.integer :total_tokens, null: false, default: 0
        t.integer :cache_read_input_tokens, null: false, default: 0
        t.integer :cache_write_input_tokens, null: false, default: 0
        t.integer :cache_write_1h_input_tokens, null: false, default: 0
        t.integer :hidden_output_tokens, null: false, default: 0
        t.decimal :input_cost, precision: 20, scale: 8
        t.decimal :cache_read_input_cost, precision: 20, scale: 8
        t.decimal :cache_write_input_cost, precision: 20, scale: 8
        t.decimal :cache_write_1h_input_cost, precision: 20, scale: 8
        t.decimal :output_cost, precision: 20, scale: 8
        t.decimal :total_cost, precision: 20, scale: 8
        t.integer :latency_ms
        t.boolean :stream, null: false, default: false
        t.string :usage_source
        t.string :provider_response_id
        t.string :pricing_mode
        tags_column.call(t)
        t.datetime :tracked_at, null: false

        t.timestamps
      end

      create_table :llm_cost_tracker_period_totals, force: true do |t|
        t.string :period, null: false
        t.date :period_start, null: false
        t.decimal :total_cost, precision: 20, scale: 8, null: false, default: 0

        t.timestamps
      end

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

      create_table :llm_cost_tracker_ingestor_leases, force: true do |t|
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

    LlmCostTracker::Ledger::Call.reset_column_information
    LlmCostTracker::Ledger::PeriodTotal.reset_column_information
    LlmCostTracker::Ledger::Ingestion::Event.reset_column_information
    LlmCostTracker::Ledger::Ingestion::Lease.reset_column_information
    LlmCostTracker::Ledger::Ingestion::Inbox.reset!
    LlmCostTracker::Ledger::Store.reset!

    allow(LlmCostTracker::Ledger::Ingestion::Worker).to receive(:ensure_started)
  end

  after do
    LlmCostTracker.shutdown!
    disconnect_database!
  end

  it "captures events into a durable inbox before ingesting them into the ledger" do
    event = LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0,
      feature: "chat"
    )

    expect(LlmCostTracker::Ledger::Ingestion::Event.count).to eq(1)
    expect(LlmCostTracker::Ledger::Call.count).to eq(0)
    expect(LlmCostTracker::Ledger::Ingestion::Event.first.event_id).to eq(event.event_id)

    expect(LlmCostTracker.flush!).to be true

    call = LlmCostTracker::Ledger::Call.first
    expect(LlmCostTracker::Ledger::Ingestion::Event.count).to eq(0)
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

    expect(LlmCostTracker::Ledger::PeriodTotal.count).to eq(0)
    expect(LlmCostTracker::Ledger::Store.daily_total(time: Time.utc(2026, 4, 18, 23))).to eq(0.0025)
    expect(LlmCostTracker::Ledger::Store.monthly_total(time: Time.utc(2026, 4, 30, 23))).to eq(0.0025)

    LlmCostTracker.flush!

    expect(LlmCostTracker::Ledger::Ingestion::Event.count).to eq(0)
    expect(LlmCostTracker::Ledger::PeriodTotal.find_by!(period: "day",
                                                        period_start: Date.new(2026, 4, 18)).total_cost.to_f)
      .to eq(0.0025)
    expect(LlmCostTracker::Ledger::Store.daily_total(time: Time.utc(2026, 4, 18, 23))).to eq(0.0025)
  end

  it "reads stored and pending budget totals in one database statement" do
    time = Time.utc(2026, 4, 18, 12)
    LlmCostTracker::Ledger::PeriodTotal.create!(
      period: "day",
      period_start: Date.new(2026, 4, 18),
      total_cost: 1.25
    )
    LlmCostTracker::Ledger::Ingestion::Event.create!(
      event_id: "pending-event",
      total_cost: 2.5,
      tracked_at: time,
      payload: "{}"
    )
    sqls = []
    allow(LlmCostTracker::Ledger::Call.connection)
      .to receive(:select_all)
      .and_wrap_original do |method, *args, **kwargs|
      sql_text = args.first.to_s
      sqls << sql_text if sql_text.include?("llm_cost_tracker_inbox_events")
      method.call(*args, **kwargs)
    end

    expect(LlmCostTracker::Ledger::Store.daily_total(time: time)).to eq(3.75)
    expect(sqls.size).to eq(1)
    expect(sqls.first).to include("llm_cost_tracker_period_totals")
    expect(sqls.first).to include("llm_cost_tracker_inbox_events")
  end

  it "ingests unknown-cost events without adding pending budget totals" do
    LlmCostTracker.configure do |config|
      config.unknown_pricing_behavior = :ignore
    end

    event = LlmCostTracker.track(
      provider: :openai,
      model: "unknown-model",
      input_tokens: 1_000,
      output_tokens: 0
    )

    expect(LlmCostTracker::Ledger::Ingestion::Event.first.total_cost).to be_nil
    expect(LlmCostTracker::Ledger::Store.daily_total(time: event.tracked_at)).to eq(0.0)

    LlmCostTracker.flush!

    expect(LlmCostTracker::Ledger::Call.find_by!(event_id: event.event_id).total_cost).to be_nil
  end

  it "does not double-count a retried inbox event that already reached the ledger" do
    event = LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )
    row = LlmCostTracker::Ledger::Ingestion::Event.first
    parsed = LlmCostTracker::Ledger::Ingestion::Inbox.event_from_row(row)

    LlmCostTracker::Ledger::Call.transaction do
      LlmCostTracker::Ledger::Store.insert_many([parsed])
    end
    LlmCostTracker.flush!

    expect(LlmCostTracker::Ledger::Call.where(event_id: event.event_id).count).to eq(1)
    expect(LlmCostTracker::Ledger::PeriodTotal.find_by!(period: "day",
                                                        period_start: Date.current).total_cost.to_f).to eq(0.0025)
    expect(LlmCostTracker::Ledger::Ingestion::Event.count).to eq(0)
  end

  it "does not increment rollups when a concurrent duplicate insert wins the race" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )
    row = LlmCostTracker::Ledger::Ingestion::Event.first
    parsed = LlmCostTracker::Ledger::Ingestion::Inbox.event_from_row(row)
    allow(LlmCostTracker::Ledger::Call).to receive(:insert_all!).and_raise(ActiveRecord::RecordNotUnique)

    expect do
      LlmCostTracker::Ledger::Store.insert_many([parsed])
    end.to raise_error(ActiveRecord::RecordNotUnique)
    expect(LlmCostTracker::Ledger::PeriodTotal.count).to eq(0)

    LlmCostTracker::Ledger::Ingestion::Event.delete_all
  end

  it "allows one ingestor lease holder until the lease expires" do
    first = LlmCostTracker::Ledger::Ingestion::LeaseClaim.new(identity: "worker-a", seconds: 10)
    second = LlmCostTracker::Ledger::Ingestion::LeaseClaim.new(identity: "worker-b", seconds: 10)

    expect(first.acquire).to be true
    expect(first.acquire).to be true
    expect(second.acquire).to be false

    LlmCostTracker::Ledger::Ingestion::Lease.find_by!(name: "default").update!(locked_until: Time.now.utc - 1)

    expect(second.acquire).to be true
  end

  it "does not ingest while another worker owns the leader lease" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )
    LlmCostTracker::Ledger::Ingestion::Lease.create!(
      name: "default",
      locked_by: "worker-a",
      locked_until: Time.now.utc + 30
    )

    expect(LlmCostTracker::Ledger::Ingestion::Worker.ingest_once).to eq(0)
    expect(LlmCostTracker::Ledger::Ingestion::Event.count).to eq(1)

    LlmCostTracker::Ledger::Ingestion::Lease.find_by!(name: "default").update!(locked_until: Time.now.utc - 1)

    expect(LlmCostTracker::Ledger::Ingestion::Worker.ingest_once).to eq(1)
    expect(LlmCostTracker::Ledger::Ingestion::Event.count).to eq(0)
  end

  it "marks failed batches for retry" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )
    allow(LlmCostTracker::Ledger::Store).to receive(:insert_many).and_raise("write failed")
    allow(LlmCostTracker::Logging).to receive(:warn)

    expect(LlmCostTracker::Ledger::Ingestion::Worker.ingest_once(require_lease: false)).to eq(0)

    row = LlmCostTracker::Ledger::Ingestion::Event.first
    expect(row.locked_at).not_to be_nil
    expect(row.locked_by).to be_nil
    expect(row.last_error).to include("write failed")

    LlmCostTracker::Ledger::Ingestion::Event.delete_all
  end

  it "quarantines invalid inbox rows without blocking valid rows behind them" do
    now = Time.utc(2026, 4, 18, 12)
    LlmCostTracker::Ledger::Ingestion::Event.create!(
      event_id: "bad-event",
      total_cost: 1.0,
      tracked_at: now,
      payload: "{",
      attempts: LlmCostTracker::Ledger::Ingestion::Inbox::MAX_ATTEMPTS - 1
    )
    event = LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )

    expect(LlmCostTracker::Ledger::Ingestion::Worker.ingest_once(require_lease: false)).to eq(2)

    bad_row = LlmCostTracker::Ledger::Ingestion::Event.find_by!(event_id: "bad-event")
    expect(bad_row.attempts).to eq(LlmCostTracker::Ledger::Ingestion::Inbox::MAX_ATTEMPTS)
    expect(bad_row.last_error).to include("JSON")
    expect(LlmCostTracker::Ledger::Call.find_by!(event_id: event.event_id)).to be_present
    expect(LlmCostTracker.flush!(timeout: 0.01)).to be true
    expect(LlmCostTracker::Ledger::Ingestion::Event.where(event_id: "bad-event")).to exist

    LlmCostTracker::Ledger::Ingestion::Event.delete_all
  end

  it "excludes quarantined inbox rows from pending budget totals" do
    time = Time.utc(2026, 4, 18, 12)
    LlmCostTracker::Ledger::Ingestion::Event.create!(
      event_id: "bad-event",
      total_cost: 1.0,
      tracked_at: time,
      payload: "{",
      attempts: LlmCostTracker::Ledger::Ingestion::Inbox::MAX_ATTEMPTS
    )

    expect(LlmCostTracker::Ledger::Store.daily_total(time: time)).to eq(0.0)
  end

  it "reports quarantined inbox rows in doctor output" do
    LlmCostTracker::Ledger::Ingestion::Event.create!(
      event_id: "bad-event",
      total_cost: 1.0,
      tracked_at: Time.utc(2026, 4, 18, 12),
      payload: "{",
      attempts: LlmCostTracker::Ledger::Ingestion::Inbox::MAX_ATTEMPTS
    )

    check = LlmCostTracker::Doctor.call.find { |item| item.name == "durable ingestion" }

    expect(check).to have_attributes(status: :warn, message: include("quarantined"))
  end

  it "reports stale pending inbox rows in doctor output" do
    time = Time.now.utc - 120
    LlmCostTracker::Ledger::Ingestion::Event.create!(
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
    LlmCostTracker::Ledger::Ingestion::Event.update_all(locked_at: Time.now.utc, locked_by: "worker-a")

    expect(LlmCostTracker.flush!(timeout: 0.01)).to be false

    LlmCostTracker::Ledger::Ingestion::Event.delete_all
  end

  it "returns false when flush reaches the timeout during an ingest attempt" do
    ingestor = LlmCostTracker::Ledger::Ingestion::Worker
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
    LlmCostTracker::Ledger::Ingestion::Event.delete_all
  end

  it "keeps flushing after a processed inbox batch" do
    ingestor = LlmCostTracker::Ledger::Ingestion::Worker
    batch = instance_double(LlmCostTracker::Ledger::Ingestion::Batch)
    allow(LlmCostTracker::Ledger::Ingestion::Batch).to receive(:new).and_return(batch)
    allow(batch).to receive(:pending?).and_return(true, false)
    allow(ingestor).to receive(:ingest_once).and_return(1)

    expect(ingestor.flush!(timeout: 0.01)).to be true
    expect(ingestor).to have_received(:ingest_once).once
  end

  it "waits between empty flush attempts only while the deadline is still open" do
    ingestor = LlmCostTracker::Ledger::Ingestion::Worker
    batch = instance_double(LlmCostTracker::Ledger::Ingestion::Batch)
    attempts = 0
    durations = []
    allow(LlmCostTracker::Ledger::Ingestion::Batch).to receive(:new).and_return(batch)
    allow(batch).to receive(:pending?).and_return(true)
    allow(ingestor).to receive(:ingest_once) do
      attempts += 1
      sleep 0.02 if attempts == 2
      0
    end
    allow(ingestor).to receive(:sleep) { |duration| durations << duration }

    expect(ingestor.flush!(timeout: 0.01)).to be false

    expect(attempts).to eq(2)
    expect(durations.length).to eq(1)
    expect(durations.first).to be > 0
    expect(durations.first).to be <= LlmCostTracker::Ledger::Ingestion::Worker::INTERVAL_SECONDS
  end

  it "does not start or flush the ingestor when durable inbox is disabled" do
    ingestor = LlmCostTracker::Ledger::Ingestion::Worker
    allow(ingestor).to receive(:ensure_started).and_wrap_original(&:call)
    allow(LlmCostTracker::Ledger::Ingestion::Inbox).to receive(:enabled?).and_return(false)

    ingestor.ensure_started

    expect(ingestor.instance_variable_get(:@thread)).to be_nil
    expect(ingestor.flush!(timeout: 0.001)).to be true
    expect(ingestor.ingest_once).to eq(0)
  ensure
    ingestor.instance_variable_set(:@thread, nil)
  end

  it "starts and stops the ingestor thread lazily" do
    allow(LlmCostTracker::Ledger::Ingestion::Worker).to receive(:ensure_started).and_wrap_original(&:call)
    LlmCostTracker::Ledger::Ingestion::Inbox.reset!

    LlmCostTracker::Ledger::Ingestion::Worker.ensure_started

    thread = LlmCostTracker::Ledger::Ingestion::Worker.instance_variable_get(:@thread)
    expect(thread).to be_alive
    expect(LlmCostTracker.shutdown!).to be true
  end

  it "wakes a running ingestor thread when a new row arrives" do
    ingestor = LlmCostTracker::Ledger::Ingestion::Worker
    thread = instance_double(Thread, alive?: true)
    allow(ingestor).to receive(:ensure_started).and_wrap_original(&:call)
    ingestor.instance_variable_set(:@pid, Process.pid)
    ingestor.instance_variable_set(:@thread, thread)

    expect(thread).to receive(:wakeup)

    ingestor.ensure_started
  ensure
    ingestor.instance_variable_set(:@thread, nil)
  end

  it "does not let an old ingestor generation resume after reset" do
    ingestor = LlmCostTracker::Ledger::Ingestion::Worker
    old_generation = 1
    ingestor.instance_variable_set(:@generation, 2)
    ingestor.instance_variable_set(:@stop_requested, false)
    allow(ingestor).to receive(:ingest_once)

    ingestor.send(:run, old_generation)

    expect(ingestor).not_to have_received(:ingest_once)
  end

  it "keeps ingestor identity when resetting inside the same process" do
    ingestor = LlmCostTracker::Ledger::Ingestion::Worker
    thread = instance_double(Thread)
    ingestor.instance_variable_set(:@pid, Process.pid)
    ingestor.instance_variable_set(:@thread, thread)
    ingestor.instance_variable_set(:@identity, "worker")

    ingestor.send(:reset_after_fork!)

    expect(ingestor.instance_variable_get(:@thread)).to eq(thread)
    expect(ingestor.instance_variable_get(:@identity)).to eq("worker")
  ensure
    ingestor.instance_variable_set(:@thread, nil)
    ingestor.instance_variable_set(:@pid, nil)
    ingestor.instance_variable_set(:@identity, nil)
  end

  it "verifies and cleans up capture through the durable inbox" do
    checks = LlmCostTracker::Ledger.verify
    check = checks.find { |item| item.name == "active_record capture" }

    expect(check).to have_attributes(status: :ok, message: include("durable inbox"))
    expect(LlmCostTracker::Ledger::Call.where("provider_response_id LIKE ?", "lct_verify_%")).to be_empty
    expect(LlmCostTracker::Ledger::Ingestion::Event.count).to eq(0)
    expect(LlmCostTracker::Ledger::PeriodTotal.sum(:total_cost).to_f).to eq(0.0)
  end

  it "reports a failed durable inbox verification when flush does not persist the row" do
    allow(LlmCostTracker).to receive(:flush!).and_return(false)

    checks = LlmCostTracker::Ledger.verify
    check = checks.find { |item| item.name == "active_record capture" }

    expect(check).to have_attributes(status: :error, message: include("persisted row"))
    expect(LlmCostTracker::Ledger::Ingestion::Event.count).to eq(0)
  end

  it "reports a missing ActiveRecord table during verification" do
    allow(LlmCostTracker::Ledger::Call).to receive(:table_exists?).and_return(false)

    checks = LlmCostTracker::Ledger.verify

    expect(checks.first).to have_attributes(status: :error, message: include("llm_api_calls table is missing"))
  end

  it "reports unexpected ActiveRecord verification failures" do
    allow(LlmCostTracker::Ledger::Call).to receive(:table_exists?).and_raise("schema failed")

    checks = LlmCostTracker::Ledger.verify

    expect(checks.first).to have_attributes(status: :error, message: include("schema failed"))
  end

  it "captures inbox rows outside caller transactions" do
    LlmCostTracker::Ledger::Call.transaction do
      LlmCostTracker.track(
        provider: :openai,
        model: "gpt-4o",
        input_tokens: 1_000,
        output_tokens: 0
      )
      raise ActiveRecord::Rollback
    end

    expect(LlmCostTracker::Ledger::Call.count).to eq(0)
    expect(LlmCostTracker::Ledger::Ingestion::Event.count).to eq(1)
  end

  it "can capture through a separate connection when the caller has an open transaction" do
    connection = LlmCostTracker::Ledger::Call.connection
    allow(connection).to receive(:transaction_open?).and_return(true)

    event = LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )

    expect(LlmCostTracker::Ledger::Ingestion::Event.find_by!(event_id: event.event_id)).to be_present
  end

  it "fails honestly when no separate connection is available inside a caller transaction" do
    connection = LlmCostTracker::Ledger::Call.connection
    allow(connection).to receive(:transaction_open?).and_return(true)
    allow(LlmCostTracker::Ledger::Ingestion::Inbox)
      .to receive(:insert_with_separate_connection)
      .and_raise(ActiveRecord::ConnectionTimeoutError)

    expect do
      LlmCostTracker.track(
        provider: :openai,
        model: "gpt-4o",
        input_tokens: 1_000,
        output_tokens: 0
      )
    end.to raise_error(LlmCostTracker::Error, /could not checkout/)

    expect(LlmCostTracker::Ledger::Ingestion::Event.count).to eq(0)
  end

  it "returns false when shutdown cannot flush cleanly" do
    allow(LlmCostTracker::Ledger::Ingestion::Worker).to receive(:flush!).and_raise("flush failed")
    allow(LlmCostTracker::Logging).to receive(:warn)

    expect(LlmCostTracker::Ledger::Ingestion::Worker.shutdown!(timeout: 0.01)).to be false
  end

  it "passes shutdown timeout through the public API" do
    allow(LlmCostTracker::Ledger::Ingestion::Worker).to receive(:shutdown!).and_return(true)
    expect(LlmCostTracker::Ledger::Ingestion::Worker)
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
    allow(LlmCostTracker::Ledger::Ingestion::Worker).to receive(:flush!) { flush_calls += 1 }

    expect(LlmCostTracker::Ledger::Ingestion::Worker.shutdown!(timeout: 0.01, drain: false)).to be true
    expect(flush_calls).to eq(0)
    expect(LlmCostTracker::Ledger::Ingestion::Event.count).to eq(1)
  end

  it "uses the leader lease when shutdown drains" do
    flush_calls = []
    allow(LlmCostTracker::Ledger::Ingestion::Worker).to receive(:flush!) do |**kwargs|
      flush_calls << kwargs
      true
    end

    expect(LlmCostTracker::Ledger::Ingestion::Worker.shutdown!(timeout: 0.01)).to be true
    expect(flush_calls).to eq([{ timeout: 0.01, require_lease: true }])
  end

  it "keeps the ingestor loop alive after transient failures" do
    ingestor = LlmCostTracker::Ledger::Ingestion::Worker
    calls = 0
    generation = 1
    ingestor.instance_variable_set(:@generation, generation)
    allow(ingestor).to receive(:sleep)
    allow(LlmCostTracker::Logging).to receive(:warn)
    allow(ActiveRecord::Base.connection_handler).to receive(:clear_active_connections!)
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
    ingestor = LlmCostTracker::Ledger::Ingestion::Worker
    generation = 1
    ingestor.instance_variable_set(:@generation, generation)
    allow(ingestor).to receive(:ingest_once) do
      ingestor.instance_variable_set(:@stop_requested, true)
      1
    end

    ingestor.instance_variable_set(:@stop_requested, false)
    ingestor.send(:run, generation)

    expect(ingestor).to have_received(:ingest_once)
  end

  it "ignores connection cleanup failures" do
    ingestor = LlmCostTracker::Ledger::Ingestion::Worker
    generation = 1
    ingestor.instance_variable_set(:@generation, generation)
    allow(ingestor).to receive(:sleep)
    allow(ingestor).to receive(:ingest_once) do
      ingestor.instance_variable_set(:@stop_requested, true)
      0
    end
    allow(ActiveRecord::Base.connection_handler).to receive(:clear_active_connections!).and_raise("cleanup failed")

    expect do
      ingestor.instance_variable_set(:@stop_requested, false)
      ingestor.send(:run, generation)
    end.not_to raise_error
  end

  it "does not acquire a leader lease while the inbox is empty" do
    ingestor = LlmCostTracker::Ledger::Ingestion::Worker
    generation = 1
    ingestor.instance_variable_set(:@generation, generation)
    batch = instance_double(LlmCostTracker::Ledger::Ingestion::Batch, claimable?: false, pending?: false)
    allow(LlmCostTracker::Ledger::Ingestion::Batch).to receive(:new).and_return(batch)
    allow(ingestor).to receive(:sleep) { ingestor.instance_variable_set(:@stop_requested, true) }
    allow(LlmCostTracker::Ledger::Ingestion::LeaseClaim).to receive(:new)

    ingestor.instance_variable_set(:@stop_requested, false)
    ingestor.send(:run, generation)

    expect(LlmCostTracker::Ledger::Ingestion::LeaseClaim).not_to have_received(:new)
  end

  it "wraps background ingestion work with the Rails executor when available" do
    ingestor = LlmCostTracker::Ledger::Ingestion::Worker
    generation = 1
    ingestor.instance_variable_set(:@generation, generation)
    executor = double("executor")
    application = double("application", executor: executor)
    stub_const("Rails", double("rails", application: application))
    allow(executor).to receive(:wrap) { |&block| block.call }
    allow(ingestor).to receive(:sleep) { ingestor.instance_variable_set(:@stop_requested, true) }
    allow(ingestor).to receive(:ingest_once).and_return(0)

    ingestor.instance_variable_set(:@stop_requested, false)
    ingestor.send(:run, generation)

    expect(executor).to have_received(:wrap)
  end

  it "runs background ingestion work without a Rails executor" do
    ingestor = LlmCostTracker::Ledger::Ingestion::Worker
    rails = double("rails")
    application = double("application")
    stub_const("Rails", rails)
    allow(rails).to receive(:respond_to?).with(:application).and_return(true)
    allow(rails).to receive(:application).and_return(application)
    allow(application).to receive(:respond_to?).with(:executor).and_return(false)
    yielded = false

    ingestor.send(:executor_wrap) { yielded = true }

    expect(yielded).to be true
  end

  it "keeps running when Rails executor lookup fails" do
    ingestor = LlmCostTracker::Ledger::Ingestion::Worker
    rails = double("rails")
    stub_const("Rails", rails)
    allow(rails).to receive(:respond_to?).with(:application).and_return(true)
    allow(rails).to receive(:application).and_raise("executor failed")
    yielded = false

    ingestor.send(:executor_wrap) { yielded = true }

    expect(yielded).to be true
  end

  it "warns when ingestor storage errors happen" do
    allow(LlmCostTracker::Logging).to receive(:warn)

    LlmCostTracker::Ledger::Ingestion::Worker.send(:handle_error, RuntimeError.new("boom"))

    expect(LlmCostTracker::Logging).to have_received(:warn)
      .with("ActiveRecord ingestor failed: RuntimeError: boom")
  end

  it "ignores wakeup races for threads that already stopped" do
    thread = double("thread", alive?: true)
    allow(thread).to receive(:wakeup).and_raise(ThreadError)

    expect do
      LlmCostTracker::Ledger::Ingestion::Worker.send(:wake_thread, thread)
    end.not_to raise_error
  end

  it "ignores failures while marking failed rows" do
    allow(LlmCostTracker::Ledger::Ingestion::Event).to receive(:where).and_raise("write failed")
    batch = LlmCostTracker::Ledger::Ingestion::Batch.new(identity: "test")

    expect do
      batch.mark_failed(
        [instance_double(LlmCostTracker::Ledger::Ingestion::Event, id: 1)],
        RuntimeError.new("boom")
      )
    end.not_to raise_error
  end
end
