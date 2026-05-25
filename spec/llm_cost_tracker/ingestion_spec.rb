# frozen_string_literal: true

require "spec_helper"
require "active_record"

RSpec.describe "ActiveRecord async inbox" do
  before do
    establish_database_connection!

    create_lct_tables!

    LlmCostTracker::Call.reset_column_information
    LlmCostTracker::CallLineItem.reset_column_information
    LlmCostTracker::CallTag.reset_column_information
    LlmCostTracker::CallRollup.reset_column_information
    LlmCostTracker::Ingestion::InboxEntry.reset_column_information
    LlmCostTracker::Ingestion::Lease.reset_column_information

    LlmCostTracker.configuration.ingestion = :async
    LlmCostTracker.configuration.cache_rollups = true
    allow(LlmCostTracker::Ingestion::Worker).to receive(:ensure_started)
  end

  after do
    LlmCostTracker::Ingestion::Worker.shutdown!
    disconnect_database!
  end

  it "uses async ingestion table names" do
    expect(LlmCostTracker::Ingestion::InboxEntry.table_name)
      .to eq("llm_cost_tracker_ingestion_inbox_entries")
    expect(LlmCostTracker::Ingestion::Lease.table_name).to eq("llm_cost_tracker_ingestion_leases")
  end

  it "captures events into an async inbox before ingesting them into the ledger" do
    event = LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      tokens: { input: 1_000, output: 0 },
      tags: { feature: "chat" }
    )

    expect(LlmCostTracker::Ingestion::InboxEntry.count).to eq(1)
    expect(LlmCostTracker::Call.count).to eq(0)
    expect(LlmCostTracker::Ingestion::InboxEntry.first.event_id).to eq(event.event_id)

    expect(LlmCostTracker::Ingestion::Worker.flush!).to be true

    call = LlmCostTracker::Call.first
    expect(LlmCostTracker::Ingestion::InboxEntry.count).to eq(0)
    expect(call.event_id).to eq(event.event_id)
    expect(call.total_cost.to_f).to eq(0.0025)
    expect(call.parsed_tags).to include("feature" => "chat")
  end

  it "wakes the worker from Tracker.record in async mode" do
    expect(LlmCostTracker::Ingestion::Worker).to receive(:ensure_started).at_least(:once)

    LlmCostTracker.track(provider: :openai, model: "gpt-4o", tokens: { input: 1, output: 0 })
  end

  it "includes pending inbox costs in call rollups before ingesting" do
    allow(Time).to receive(:now).and_return(Time.utc(2026, 4, 18, 12))

    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      tokens: { input: 1_000, output: 0 },
    )

    expect(LlmCostTracker::CallRollup.count).to eq(0)
    daily_total = LlmCostTracker::Ledger::Period::Totals
                  .call(%i[day], time: Time.utc(2026, 4, 18, 23))
                  .fetch(:day)
    monthly_total = LlmCostTracker::Ledger::Period::Totals
                    .call(%i[month], time: Time.utc(2026, 4, 30, 23))
                    .fetch(:month)
    expect(daily_total).to eq(0.0025)
    expect(monthly_total).to eq(0.0025)

    LlmCostTracker::Ingestion::Worker.flush!

    expect(LlmCostTracker::Ingestion::InboxEntry.count).to eq(0)
    expect(LlmCostTracker::CallRollup.find_by!(
      period: "day",
      period_start: Date.new(2026, 4, 18)
    ).total_cost.to_f)
      .to eq(0.0025)
    daily_total = LlmCostTracker::Ledger::Period::Totals
                  .call(%i[day], time: Time.utc(2026, 4, 18, 23))
                  .fetch(:day)
    expect(daily_total).to eq(0.0025)
  end

  it "reads stored and pending budget totals in one database statement" do
    time = Time.utc(2026, 4, 18, 12)
    LlmCostTracker::CallRollup.create!(
      period: "day",
      period_start: Date.new(2026, 4, 18),
      total_cost: 1.25
    )
    LlmCostTracker::Ingestion::InboxEntry.create!(
      event_id: "pending-event",
      total_cost: 2.5,
      tracked_at: time,
      payload: "{}"
    )
    sqls = []
    allow(LlmCostTracker::Call)
      .to receive(:find_by_sql)
      .and_wrap_original do |method, *args, **kwargs|
      sql_text = args.first.to_s
      sqls << sql_text if sql_text.include?("llm_cost_tracker_ingestion_inbox_entries")
      method.call(*args, **kwargs)
    end

    total = LlmCostTracker::Ledger::Period::Totals.call(%i[day], time: time).fetch(:day)
    expect(total).to eq(3.75)
    expect(sqls.size).to eq(1)
    expect(sqls.first).to include("llm_cost_tracker_call_rollups")
    expect(sqls.first).to include("llm_cost_tracker_ingestion_inbox_entries")
  end

  it "ingests unknown-cost events without adding pending budget totals" do
    LlmCostTracker.configure do |config|
      config.unknown_pricing_behavior = :ignore
    end

    event = LlmCostTracker.track(
      provider: :openai,
      model: "unknown-model",
      tokens: { input: 1_000, output: 0 },
    )

    expect(LlmCostTracker::Ingestion::InboxEntry.first.total_cost).to be_nil
    total = LlmCostTracker::Ledger::Period::Totals.call(%i[day], time: event.tracked_at).fetch(:day)
    expect(total).to eq(0.0)

    LlmCostTracker::Ingestion::Worker.flush!

    expect(LlmCostTracker::Call.find_by!(event_id: event.event_id).total_cost).to be_nil
  end

  it "does not double-count a retried inbox entry that already reached the ledger" do
    event = LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      tokens: { input: 1_000, output: 0 },
    )
    row = LlmCostTracker::Ingestion::InboxEntry.first
    parsed = LlmCostTracker::Ingestion::Inbox.event_from_row(row)

    LlmCostTracker::Call.transaction do
      LlmCostTracker::Ledger::Store.insert([parsed])
    end
    LlmCostTracker::Ingestion::Worker.flush!

    expect(LlmCostTracker::Call.where(event_id: event.event_id).count).to eq(1)
    expect(LlmCostTracker::CallRollup.find_by!(
      period: "day",
      period_start: Date.current
    ).total_cost.to_f).to eq(0.0025)
    expect(LlmCostTracker::Ingestion::InboxEntry.count).to eq(0)
  end

  it "persists fresh events in a mixed batch where one event_id already reached the ledger" do
    stale_event = LlmCostTracker.track(provider: :openai, model: "gpt-4o", tokens: { input: 1_000, output: 0 })
    fresh_event = LlmCostTracker.track(provider: :openai, model: "gpt-4o-mini", tokens: { input: 500, output: 0 })
    rows = LlmCostTracker::Ingestion::InboxEntry.order(:id).to_a

    LlmCostTracker::Call.transaction do
      LlmCostTracker::Ledger::Store.insert([LlmCostTracker::Ingestion::Inbox.event_from_row(rows.first)])
    end
    LlmCostTracker::Ingestion::Worker.flush!

    persisted = LlmCostTracker::Call.where(event_id: [stale_event.event_id, fresh_event.event_id]).pluck(:event_id)
    expect(persisted).to contain_exactly(stale_event.event_id, fresh_event.event_id)
    expect(LlmCostTracker::Ingestion::InboxEntry.count).to eq(0)
  end

  it "does not increment rollups when a concurrent duplicate insert wins the race" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      tokens: { input: 1_000, output: 0 },
    )
    row = LlmCostTracker::Ingestion::InboxEntry.first
    parsed = LlmCostTracker::Ingestion::Inbox.event_from_row(row)
    allow(LlmCostTracker::Call).to receive(:insert_all!).and_raise(ActiveRecord::RecordNotUnique)

    expect do
      LlmCostTracker::Ledger::Store.insert([parsed])
    end.to raise_error(ActiveRecord::RecordNotUnique)
    expect(LlmCostTracker::CallRollup.count).to eq(0)

    LlmCostTracker::Ingestion::InboxEntry.delete_all
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
      tokens: { input: 1_000, output: 0 },
    )
    LlmCostTracker::Ingestion::Lease.create!(
      name: "default",
      locked_by: "worker-a",
      locked_until: Time.now.utc + 30
    )

    expect(LlmCostTracker::Ingestion::Worker.ingest_once).to eq(0)
    expect(LlmCostTracker::Ingestion::InboxEntry.count).to eq(1)

    LlmCostTracker::Ingestion::Lease.find_by!(name: "default").update!(locked_until: Time.now.utc - 1)

    expect(LlmCostTracker::Ingestion::Worker.ingest_once).to eq(1)
    expect(LlmCostTracker::Ingestion::InboxEntry.count).to eq(0)
  end

  it "marks failed batches for retry" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      tokens: { input: 1_000, output: 0 },
    )
    allow(LlmCostTracker::Ledger::Store).to receive(:insert).and_raise("write failed")
    allow(LlmCostTracker::Logging).to receive(:warn)

    expect(LlmCostTracker::Ingestion::Worker.ingest_once(require_lease: false)).to eq(0)

    row = LlmCostTracker::Ingestion::InboxEntry.first
    expect(row.locked_at).not_to be_nil
    expect(row.locked_by).to be_nil
    expect(row.last_error).to include("write failed")

    LlmCostTracker::Ingestion::InboxEntry.delete_all
  end

  it "quarantines invalid inbox entries without blocking valid rows behind them" do
    now = Time.utc(2026, 4, 18, 12)
    LlmCostTracker::Ingestion::InboxEntry.create!(
      event_id: "bad-event",
      total_cost: 1.0,
      tracked_at: now,
      payload: "{",
      attempts: LlmCostTracker::Ingestion::InboxEntry::MAX_ATTEMPTS_BEFORE_QUARANTINE - 1
    )
    event = LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      tokens: { input: 1_000, output: 0 },
    )

    expect(LlmCostTracker::Ingestion::Worker.ingest_once(require_lease: false)).to eq(2)

    bad_row = LlmCostTracker::Ingestion::InboxEntry.find_by!(event_id: "bad-event")
    expect(bad_row.attempts).to eq(LlmCostTracker::Ingestion::InboxEntry::MAX_ATTEMPTS_BEFORE_QUARANTINE)
    expect(bad_row.last_error).to include("JSON")
    expect(LlmCostTracker::Call.find_by!(event_id: event.event_id)).to be_present
    expect(LlmCostTracker::Ingestion::Worker.flush!(timeout: 0.01)).to be true
    expect(LlmCostTracker::Ingestion::InboxEntry.where(event_id: "bad-event")).to exist

    LlmCostTracker::Ingestion::InboxEntry.delete_all
  end

  it "excludes quarantined inbox entries from pending budget totals" do
    time = Time.utc(2026, 4, 18, 12)
    LlmCostTracker::Ingestion::InboxEntry.create!(
      event_id: "bad-event",
      total_cost: 1.0,
      tracked_at: time,
      payload: "{",
      attempts: LlmCostTracker::Ingestion::InboxEntry::MAX_ATTEMPTS_BEFORE_QUARANTINE
    )

    total = LlmCostTracker::Ledger::Period::Totals.call(%i[day], time: time).fetch(:day)
    expect(total).to eq(0.0)
  end

  it "warns to Logging when an inbox row reaches MAX_ATTEMPTS so production sees the quarantine at the moment it happens" do
    allow(LlmCostTracker::Logging).to receive(:warn)
    row = LlmCostTracker::Ingestion::InboxEntry.create!(
      event_id: "bad-event",
      total_cost: 1.0,
      tracked_at: Time.utc(2026, 4, 18, 12),
      payload: "{",
      attempts: LlmCostTracker::Ingestion::InboxEntry::MAX_ATTEMPTS_BEFORE_QUARANTINE,
      locked_by: "worker-x"
    )

    LlmCostTracker::Ingestion::Batch.new(identity: "worker-x").mark_failed([row], RuntimeError.new("boom"))

    expect(LlmCostTracker::Logging).to have_received(:warn)
      .with(include("MAX_ATTEMPTS_BEFORE_QUARANTINE").and(include(row.id.to_s)))
  end

  it "times out flush when every row is leased by another worker" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      tokens: { input: 1_000, output: 0 },
    )
    LlmCostTracker::Ingestion::InboxEntry.update_all(locked_at: Time.now.utc, locked_by: "worker-a")

    expect(LlmCostTracker::Ingestion::Worker.flush!(timeout: 0.01)).to be false

    LlmCostTracker::Ingestion::InboxEntry.delete_all
  end

  it "returns false when flush reaches the timeout during an ingest attempt" do
    ingestor = LlmCostTracker::Ingestion::Worker
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      tokens: { input: 1_000, output: 0 },
    )
    allow(ingestor).to receive(:ingest_once) do
      sleep 0.02
      0
    end

    expect(ingestor.flush!(timeout: 0.001)).to be false
  ensure
    LlmCostTracker::Ingestion::InboxEntry.delete_all
  end

  it "treats nil flush timeouts as the documented default" do
    expect(LlmCostTracker::Ingestion::Worker.send(:flush_timeout_seconds, nil))
      .to eq(LlmCostTracker::Ingestion::Worker::FLUSH_TIMEOUT_SECONDS)
  end

  it "treats non-numeric flush timeouts as the documented default" do
    expect(LlmCostTracker::Ingestion::Worker.send(:flush_timeout_seconds, "soon"))
      .to eq(LlmCostTracker::Ingestion::Worker::FLUSH_TIMEOUT_SECONDS)
  end

  it "treats non-positive flush timeouts as the documented default" do
    expect(LlmCostTracker::Ingestion::Worker.send(:flush_timeout_seconds, 0))
      .to eq(LlmCostTracker::Ingestion::Worker::FLUSH_TIMEOUT_SECONDS)
  end

  it "treats infinite flush timeouts as the documented default" do
    expect(LlmCostTracker::Ingestion::Worker.send(:flush_timeout_seconds, Float::INFINITY))
      .to eq(LlmCostTracker::Ingestion::Worker::FLUSH_TIMEOUT_SECONDS)
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
    expect(LlmCostTracker::Ingestion::Worker.shutdown!).to be true
  end

  it "refuses to respawn the ingestor after shutdown until reset clears the stop flag" do
    ingestor = LlmCostTracker::Ingestion::Worker
    allow(ingestor).to receive(:ensure_started).and_wrap_original(&:call)

    ingestor.ensure_started
    expect(ingestor.instance_variable_get(:@thread)).to be_a(Thread)

    expect(ingestor.shutdown!(drain: false)).to be true
    expect(ingestor.instance_variable_get(:@thread)).to be_nil

    ingestor.ensure_started
    expect(ingestor.instance_variable_get(:@thread)).to be_nil

    ingestor.reset!
    ingestor.ensure_started
    expect(ingestor.instance_variable_get(:@thread)).to be_a(Thread)
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

  it "verifies and cleans up capture through the async inbox" do
    checks = LlmCostTracker::Ingestion.verify
    check = checks.find { |item| item.name == "active_record capture" }

    expect(check).to have_attributes(status: :ok, message: include("async inbox"))
    expect(LlmCostTracker::Call.where("provider_response_id LIKE ?", "lct_verify_%")).to be_empty
    expect(LlmCostTracker::Ingestion::InboxEntry.count).to eq(0)
    expect(LlmCostTracker::CallRollup.sum(:total_cost).to_f).to eq(0.0)
  end

  it "reports a failed async inbox verification when flush does not persist the row" do
    allow(LlmCostTracker::Ingestion::Worker).to receive(:flush!).and_return(false)

    checks = LlmCostTracker::Ingestion.verify
    check = checks.find { |item| item.name == "active_record capture" }

    expect(check).to have_attributes(status: :error, message: include("persisted row"))
    expect(LlmCostTracker::Ingestion::InboxEntry.count).to eq(0)
  end

  it "purges the synthetic inbox row when verification track raises before returning the event" do
    captured_response_id = nil
    allow(LlmCostTracker).to receive(:track).and_wrap_original do |original, **kwargs|
      captured_response_id = kwargs[:provider_response_id]
      original.call(**kwargs)
      raise LlmCostTracker::BudgetExceededError.new(budget_type: :monthly, total: 1.0, budget: 0.5)
    end

    checks = LlmCostTracker::Ingestion.verify
    check = checks.find { |item| item.name == "active_record capture" }

    expect(check).to have_attributes(status: :error, message: include("blocked by budget guardrail"))
    expect(captured_response_id).to be_a(String)
    expect(LlmCostTracker::Ingestion::InboxEntry.where("payload LIKE ?", "%#{captured_response_id}%")).to be_empty
  end

  it "reports a missing ActiveRecord table during verification" do
    allow(LlmCostTracker::Call).to receive(:table_exists?).and_return(false)

    checks = LlmCostTracker::Ingestion.verify

    expect(checks.first).to have_attributes(status: :error, message: include("llm_cost_tracker_calls table is missing"))
  end

  it "raises the current call table name when schema verification has no ledger table" do
    allow(LlmCostTracker::Call).to receive(:table_exists?).and_return(false)

    expect { LlmCostTracker::Ingestion.ensure_current_schema! }
      .to raise_error(LlmCostTracker::Error, include("llm_cost_tracker_calls table is missing"))
  end

  it "raises when llm_cost_tracker_call_line_items has drifted" do
    ActiveRecord::Base.connection.drop_table(:llm_cost_tracker_call_line_items)
    LlmCostTracker::CallLineItem.reset_column_information

    expect { LlmCostTracker::Ingestion.ensure_current_schema! }
      .to raise_error(LlmCostTracker::Error,
                      include("llm_cost_tracker_call_line_items table is not on the current schema"))
  end

  it "raises when llm_cost_tracker_call_tags has drifted" do
    ActiveRecord::Base.connection.drop_table(:llm_cost_tracker_call_tags)
    LlmCostTracker::CallTag.reset_column_information

    expect { LlmCostTracker::Ingestion.ensure_current_schema! }
      .to raise_error(LlmCostTracker::Error,
                      include("llm_cost_tracker_call_tags table is not on the current schema"))
  end

  it "reports unexpected ActiveRecord verification failures" do
    allow(LlmCostTracker::Call).to receive(:table_exists?).and_raise("schema failed")

    checks = LlmCostTracker::Ingestion.verify

    expect(checks.first).to have_attributes(status: :error, message: include("schema failed"))
  end

  it "captures inbox entries outside caller transactions" do
    LlmCostTracker::Call.transaction do
      LlmCostTracker.track(
        provider: :openai,
        model: "gpt-4o",
        tokens: { input: 1_000, output: 0 },
      )
      raise ActiveRecord::Rollback
    end

    expect(LlmCostTracker::Call.count).to eq(0)
    expect(LlmCostTracker::Ingestion::InboxEntry.count).to eq(1)
  end

  it "can capture through a separate connection when the caller has an open transaction" do
    connection = LlmCostTracker::Call.connection
    allow(connection).to receive(:transaction_open?).and_return(true)

    event = LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      tokens: { input: 1_000, output: 0 },
    )

    expect(LlmCostTracker::Ingestion::InboxEntry.find_by!(event_id: event.event_id)).to be_present
  end

  it "fails honestly when the isolated pool cannot lend a connection" do
    allow(LlmCostTracker::Ingestion::Pool)
      .to receive(:with_connection)
      .and_raise(ActiveRecord::ConnectionTimeoutError)

    expect do
      LlmCostTracker.track(
        provider: :openai,
        model: "gpt-4o",
        tokens: { input: 1_000, output: 0 }
      )
    end.to raise_error(LlmCostTracker::Error, /could not checkout/)

    expect(LlmCostTracker::Ingestion::InboxEntry.count).to eq(0)
  end

  it "returns false when shutdown cannot flush cleanly" do
    allow(LlmCostTracker::Ingestion::Worker).to receive(:flush!).and_raise("flush failed")
    allow(LlmCostTracker::Logging).to receive(:warn)

    expect(LlmCostTracker::Ingestion::Worker.shutdown!(timeout: 0.01)).to be false
  end

  it "can stop the ingestor without draining inbox rows" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      tokens: { input: 1_000, output: 0 },
    )
    flush_calls = 0
    allow(LlmCostTracker::Ingestion::Worker).to receive(:flush!) { flush_calls += 1 }

    expect(LlmCostTracker::Ingestion::Worker.shutdown!(timeout: 0.01, drain: false)).to be true
    expect(flush_calls).to eq(0)
    expect(LlmCostTracker::Ingestion::InboxEntry.count).to eq(1)
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
    allow(LlmCostTracker::Ingestion::InboxEntry).to receive(:where).and_raise("write failed")
    batch = LlmCostTracker::Ingestion::Batch.new(identity: "test")

    expect do
      batch.mark_failed(
        [instance_double(LlmCostTracker::Ingestion::InboxEntry, id: 1)],
        RuntimeError.new("boom")
      )
    end.not_to raise_error
  end
end
