# frozen_string_literal: true

require "spec_helper"
require "active_record"

RSpec.describe "ActiveRecord durable inbox" do
  before do
    establish_database_connection!

    create_lct_tables!

    LlmCostTracker::Ledger::Call.reset_column_information
    LlmCostTracker::Ledger::ServiceCharge.reset_column_information
    LlmCostTracker::Ledger::Period::Total.reset_column_information
    LlmCostTracker::Ingestion::Event.reset_column_information
    LlmCostTracker::Ingestion::Lease.reset_column_information

    allow(LlmCostTracker::Ingestion::Worker).to receive(:ensure_started)
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

    expect(LlmCostTracker::Ingestion::Event.count).to eq(1)
    expect(LlmCostTracker::Ledger::Call.count).to eq(0)
    expect(LlmCostTracker::Ingestion::Event.first.event_id).to eq(event.event_id)

    expect(LlmCostTracker.flush!).to be true

    call = LlmCostTracker::Ledger::Call.first
    expect(LlmCostTracker::Ingestion::Event.count).to eq(0)
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

    expect(LlmCostTracker::Ledger::Period::Total.count).to eq(0)
    daily_total = LlmCostTracker::Ledger::Period::Totals
                  .call(%i[daily], time: Time.utc(2026, 4, 18, 23))
                  .fetch(:daily)
    monthly_total = LlmCostTracker::Ledger::Period::Totals
                    .call(%i[monthly], time: Time.utc(2026, 4, 30, 23))
                    .fetch(:monthly)
    expect(daily_total).to eq(0.0025)
    expect(monthly_total).to eq(0.0025)

    LlmCostTracker.flush!

    expect(LlmCostTracker::Ingestion::Event.count).to eq(0)
    expect(LlmCostTracker::Ledger::Period::Total.find_by!(
      period: "day",
      period_start: Date.new(2026, 4, 18)
    ).total_cost.to_f)
      .to eq(0.0025)
    daily_total = LlmCostTracker::Ledger::Period::Totals
                  .call(%i[daily], time: Time.utc(2026, 4, 18, 23))
                  .fetch(:daily)
    expect(daily_total).to eq(0.0025)
  end

  it "reads stored and pending budget totals in one database statement" do
    time = Time.utc(2026, 4, 18, 12)
    LlmCostTracker::Ledger::Period::Total.create!(
      period: "day",
      period_start: Date.new(2026, 4, 18),
      total_cost: 1.25
    )
    LlmCostTracker::Ingestion::Event.create!(
      event_id: "pending-event",
      total_cost: 2.5,
      tracked_at: time,
      payload: "{}"
    )
    sqls = []
    allow(LlmCostTracker::Ledger::Call)
      .to receive(:find_by_sql)
      .and_wrap_original do |method, *args, **kwargs|
      sql_text = args.first.to_s
      sqls << sql_text if sql_text.include?("llm_cost_tracker_inbox_events")
      method.call(*args, **kwargs)
    end

    total = LlmCostTracker::Ledger::Period::Totals.call(%i[daily], time: time).fetch(:daily)
    expect(total).to eq(3.75)
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

    expect(LlmCostTracker::Ingestion::Event.first.total_cost).to be_nil
    total = LlmCostTracker::Ledger::Period::Totals.call(%i[daily], time: event.tracked_at).fetch(:daily)
    expect(total).to eq(0.0)

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
    row = LlmCostTracker::Ingestion::Event.first
    parsed = LlmCostTracker::Ingestion::Inbox.event_from_row(row)

    LlmCostTracker::Ledger::Call.transaction do
      LlmCostTracker::Ledger::Store.insert_many([parsed])
    end
    LlmCostTracker.flush!

    expect(LlmCostTracker::Ledger::Call.where(event_id: event.event_id).count).to eq(1)
    expect(LlmCostTracker::Ledger::Period::Total.find_by!(
      period: "day",
      period_start: Date.current
    ).total_cost.to_f).to eq(0.0025)
    expect(LlmCostTracker::Ingestion::Event.count).to eq(0)
  end

  it "does not increment rollups when a concurrent duplicate insert wins the race" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )
    row = LlmCostTracker::Ingestion::Event.first
    parsed = LlmCostTracker::Ingestion::Inbox.event_from_row(row)
    allow(LlmCostTracker::Ledger::Call).to receive(:insert_all!).and_raise(ActiveRecord::RecordNotUnique)

    expect do
      LlmCostTracker::Ledger::Store.insert_many([parsed])
    end.to raise_error(ActiveRecord::RecordNotUnique)
    expect(LlmCostTracker::Ledger::Period::Total.count).to eq(0)

    LlmCostTracker::Ingestion::Event.delete_all
  end

  it "allows one ingestor lease holder until the lease expires" do
    first = LlmCostTracker::Ingestion::LeaseClaim.new(identity: "worker-a", seconds: 10)
    second = LlmCostTracker::Ingestion::LeaseClaim.new(identity: "worker-b", seconds: 10)

    expect(first.acquire).to be true
    expect(first.acquire).to be true
    expect(second.acquire).to be false

    LlmCostTracker::Ingestion::Lease.find_by!(name: "default").update!(locked_until: Time.now.utc - 1)

    expect(second.acquire).to be true
  end

  it "does not ingest while another worker owns the leader lease" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )
    LlmCostTracker::Ingestion::Lease.create!(
      name: "default",
      locked_by: "worker-a",
      locked_until: Time.now.utc + 30
    )

    expect(LlmCostTracker::Ingestion::Worker.ingest_once).to eq(0)
    expect(LlmCostTracker::Ingestion::Event.count).to eq(1)

    LlmCostTracker::Ingestion::Lease.find_by!(name: "default").update!(locked_until: Time.now.utc - 1)

    expect(LlmCostTracker::Ingestion::Worker.ingest_once).to eq(1)
    expect(LlmCostTracker::Ingestion::Event.count).to eq(0)
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

    expect(LlmCostTracker::Ingestion::Worker.ingest_once(require_lease: false)).to eq(0)

    row = LlmCostTracker::Ingestion::Event.first
    expect(row.locked_at).not_to be_nil
    expect(row.locked_by).to be_nil
    expect(row.last_error).to include("write failed")

    LlmCostTracker::Ingestion::Event.delete_all
  end

  it "quarantines invalid inbox rows without blocking valid rows behind them" do
    now = Time.utc(2026, 4, 18, 12)
    LlmCostTracker::Ingestion::Event.create!(
      event_id: "bad-event",
      total_cost: 1.0,
      tracked_at: now,
      payload: "{",
      attempts: LlmCostTracker::Ingestion::Event::MAX_ATTEMPTS - 1
    )
    event = LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )

    expect(LlmCostTracker::Ingestion::Worker.ingest_once(require_lease: false)).to eq(2)

    bad_row = LlmCostTracker::Ingestion::Event.find_by!(event_id: "bad-event")
    expect(bad_row.attempts).to eq(LlmCostTracker::Ingestion::Event::MAX_ATTEMPTS)
    expect(bad_row.last_error).to include("JSON")
    expect(LlmCostTracker::Ledger::Call.find_by!(event_id: event.event_id)).to be_present
    expect(LlmCostTracker.flush!(timeout: 0.01)).to be true
    expect(LlmCostTracker::Ingestion::Event.where(event_id: "bad-event")).to exist

    LlmCostTracker::Ingestion::Event.delete_all
  end

  it "excludes quarantined inbox rows from pending budget totals" do
    time = Time.utc(2026, 4, 18, 12)
    LlmCostTracker::Ingestion::Event.create!(
      event_id: "bad-event",
      total_cost: 1.0,
      tracked_at: time,
      payload: "{",
      attempts: LlmCostTracker::Ingestion::Event::MAX_ATTEMPTS
    )

    total = LlmCostTracker::Ledger::Period::Totals.call(%i[daily], time: time).fetch(:daily)
    expect(total).to eq(0.0)
  end

  it "reports quarantined inbox rows in doctor output" do
    LlmCostTracker::Ingestion::Event.create!(
      event_id: "bad-event",
      total_cost: 1.0,
      tracked_at: Time.utc(2026, 4, 18, 12),
      payload: "{",
      attempts: LlmCostTracker::Ingestion::Event::MAX_ATTEMPTS
    )

    check = LlmCostTracker::Doctor.call.find { |item| item.name == "durable ingestion" }

    expect(check).to have_attributes(status: :warn, message: include("quarantined"))
  end

  it "reports stale pending inbox rows in doctor output" do
    time = Time.now.utc - 120
    LlmCostTracker::Ingestion::Event.create!(
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
    LlmCostTracker::Ingestion::Event.update_all(locked_at: Time.now.utc, locked_by: "worker-a")

    expect(LlmCostTracker.flush!(timeout: 0.01)).to be false

    LlmCostTracker::Ingestion::Event.delete_all
  end

  it "returns false when flush reaches the timeout during an ingest attempt" do
    ingestor = LlmCostTracker::Ingestion::Worker
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
    LlmCostTracker::Ingestion::Event.delete_all
  end

  it "keeps flushing after a processed inbox batch" do
    ingestor = LlmCostTracker::Ingestion::Worker
    batch = instance_double(LlmCostTracker::Ingestion::Batch)
    allow(LlmCostTracker::Ingestion::Batch).to receive(:new).and_return(batch)
    allow(batch).to receive(:pending?).and_return(true, false)
    allow(ingestor).to receive(:ingest_once).and_return(1)

    expect(ingestor.flush!(timeout: 0.01)).to be true
    expect(ingestor).to have_received(:ingest_once).once
  end

  it "waits between empty flush attempts only while the deadline is still open" do
    ingestor = LlmCostTracker::Ingestion::Worker
    batch = instance_double(LlmCostTracker::Ingestion::Batch)
    attempts = 0
    durations = []
    allow(LlmCostTracker::Ingestion::Batch).to receive(:new).and_return(batch)
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
    expect(durations.first).to be <= LlmCostTracker::Ingestion::Worker::INTERVAL_SECONDS
  end

  it "starts and stops the ingestor thread lazily" do
    allow(LlmCostTracker::Ingestion::Worker).to receive(:ensure_started).and_wrap_original(&:call)

    LlmCostTracker::Ingestion::Worker.ensure_started

    thread = LlmCostTracker::Ingestion::Worker.instance_variable_get(:@thread)
    expect(thread).to be_alive
    expect(LlmCostTracker.shutdown!).to be true
  end

  it "wakes a running ingestor thread when a new row arrives" do
    ingestor = LlmCostTracker::Ingestion::Worker
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
    ingestor = LlmCostTracker::Ingestion::Worker
    old_generation = 1
    ingestor.instance_variable_set(:@generation, 2)
    ingestor.instance_variable_set(:@stop_requested, false)
    allow(ingestor).to receive(:ingest_once)

    ingestor.send(:run, old_generation)

    expect(ingestor).not_to have_received(:ingest_once)
  end

  it "keeps ingestor identity when resetting inside the same process" do
    ingestor = LlmCostTracker::Ingestion::Worker
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
    checks = LlmCostTracker::Ingestion.verify
    check = checks.find { |item| item.name == "active_record capture" }

    expect(check).to have_attributes(status: :ok, message: include("durable inbox"))
    expect(LlmCostTracker::Ledger::Call.where("provider_response_id LIKE ?", "lct_verify_%")).to be_empty
    expect(LlmCostTracker::Ingestion::Event.count).to eq(0)
    expect(LlmCostTracker::Ledger::Period::Total.sum(:total_cost).to_f).to eq(0.0)
  end

  it "reports a failed durable inbox verification when flush does not persist the row" do
    allow(LlmCostTracker).to receive(:flush!).and_return(false)

    checks = LlmCostTracker::Ingestion.verify
    check = checks.find { |item| item.name == "active_record capture" }

    expect(check).to have_attributes(status: :error, message: include("persisted row"))
    expect(LlmCostTracker::Ingestion::Event.count).to eq(0)
  end

  it "reports a missing ActiveRecord table during verification" do
    allow(LlmCostTracker::Ledger::Call).to receive(:table_exists?).and_return(false)

    checks = LlmCostTracker::Ingestion.verify

    expect(checks.first).to have_attributes(status: :error, message: include("llm_api_calls table is missing"))
  end

  it "reports unexpected ActiveRecord verification failures" do
    allow(LlmCostTracker::Ledger::Call).to receive(:table_exists?).and_raise("schema failed")

    checks = LlmCostTracker::Ingestion.verify

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
    expect(LlmCostTracker::Ingestion::Event.count).to eq(1)
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

    expect(LlmCostTracker::Ingestion::Event.find_by!(event_id: event.event_id)).to be_present
  end

  it "fails honestly when no separate connection is available inside a caller transaction" do
    connection = LlmCostTracker::Ledger::Call.connection
    allow(connection).to receive(:transaction_open?).and_return(true)
    allow(LlmCostTracker::Ingestion::Inbox)
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

    expect(LlmCostTracker::Ingestion::Event.count).to eq(0)
  end

  it "returns false when shutdown cannot flush cleanly" do
    allow(LlmCostTracker::Ingestion::Worker).to receive(:flush!).and_raise("flush failed")
    allow(LlmCostTracker::Logging).to receive(:warn)

    expect(LlmCostTracker::Ingestion::Worker.shutdown!(timeout: 0.01)).to be false
  end

  it "passes shutdown timeout through the public API" do
    allow(LlmCostTracker::Ingestion::Worker).to receive(:shutdown!).and_return(true)
    expect(LlmCostTracker::Ingestion::Worker)
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
    allow(LlmCostTracker::Ingestion::Worker).to receive(:flush!) { flush_calls += 1 }

    expect(LlmCostTracker::Ingestion::Worker.shutdown!(timeout: 0.01, drain: false)).to be true
    expect(flush_calls).to eq(0)
    expect(LlmCostTracker::Ingestion::Event.count).to eq(1)
  end

  it "uses the leader lease when shutdown drains" do
    flush_calls = []
    allow(LlmCostTracker::Ingestion::Worker).to receive(:flush!) do |**kwargs|
      flush_calls << kwargs
      true
    end

    expect(LlmCostTracker::Ingestion::Worker.shutdown!(timeout: 0.01)).to be true
    expect(flush_calls).to eq([{ timeout: 0.01, require_lease: true }])
  end

  it "keeps the ingestor loop alive after transient failures" do
    ingestor = LlmCostTracker::Ingestion::Worker
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
    ingestor = LlmCostTracker::Ingestion::Worker
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
    ingestor = LlmCostTracker::Ingestion::Worker
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
    ingestor = LlmCostTracker::Ingestion::Worker
    generation = 1
    ingestor.instance_variable_set(:@generation, generation)
    batch = instance_double(LlmCostTracker::Ingestion::Batch, claimable?: false, pending?: false)
    allow(LlmCostTracker::Ingestion::Batch).to receive(:new).and_return(batch)
    allow(ingestor).to receive(:sleep) { ingestor.instance_variable_set(:@stop_requested, true) }
    allow(LlmCostTracker::Ingestion::LeaseClaim).to receive(:new)

    ingestor.instance_variable_set(:@stop_requested, false)
    ingestor.send(:run, generation)

    expect(LlmCostTracker::Ingestion::LeaseClaim).not_to have_received(:new)
  end

  it "wraps background ingestion work with the Rails executor when available" do
    ingestor = LlmCostTracker::Ingestion::Worker
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
    ingestor = LlmCostTracker::Ingestion::Worker
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
    ingestor = LlmCostTracker::Ingestion::Worker
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

    LlmCostTracker::Ingestion::Worker.send(:handle_error, RuntimeError.new("boom"))

    expect(LlmCostTracker::Logging).to have_received(:warn)
      .with("ActiveRecord ingestor failed: RuntimeError: boom")
  end

  it "ignores wakeup races for threads that already stopped" do
    thread = double("thread", alive?: true)
    allow(thread).to receive(:wakeup).and_raise(ThreadError)

    expect do
      LlmCostTracker::Ingestion::Worker.send(:wake_thread, thread)
    end.not_to raise_error
  end

  it "ignores failures while marking failed rows" do
    allow(LlmCostTracker::Ingestion::Event).to receive(:where).and_raise("write failed")
    batch = LlmCostTracker::Ingestion::Batch.new(identity: "test")

    expect do
      batch.mark_failed(
        [instance_double(LlmCostTracker::Ingestion::Event, id: 1)],
        RuntimeError.new("boom")
      )
    end.not_to raise_error
  end
end
