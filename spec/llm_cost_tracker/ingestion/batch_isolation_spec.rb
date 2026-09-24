# frozen_string_literal: true

require "spec_helper"
require "active_record"

RSpec.describe LlmCostTracker::Ingestion::Batch do
  let(:inbox) { LlmCostTracker::Ingestion::InboxEntry }
  let(:max_attempts) { LlmCostTracker::Ingestion::InboxEntry::MAX_ATTEMPTS_BEFORE_QUARANTINE }

  before do
    establish_database_connection!
    create_lct_tables!
    [LlmCostTracker::Call, LlmCostTracker::CallLineItem, LlmCostTracker::CallTag, LlmCostTracker::CallRollup,
     LlmCostTracker::Ingestion::InboxEntry, LlmCostTracker::Ingestion::Lease].each(&:reset_column_information)
    allow(LlmCostTracker::Ingestion::Worker).to receive(:ensure_started)
  end

  after do
    LlmCostTracker::Ingestion::Worker.shutdown!
    disconnect_database!
  end

  def track(**overrides)
    LlmCostTracker.track(provider: :openai, model: "gpt-4o",
                         tokens: { input_tokens: 1_000_000, output_tokens: 0 }, **overrides)
  end

  def drain_cycle(identity = "worker-a")
    LlmCostTracker::Ingestion::Batch.new(identity: identity).ingest
  rescue StandardError
    nil
  ensure
    inbox.update_all(locked_at: Time.now.utc - 3_600)
  end

  def enqueue_unstorable_row
    event = track
    row = inbox.find_by!(event_id: event.event_id)
    payload = JSON.parse(row.payload)
    payload["line_items"] << payload["line_items"].first.merge("quantity" => "1e25", "kind" => "overflow")
    row.update!(payload: JSON.generate(payload))
    event
  end

  describe "async batch isolation" do
    before do
      LlmCostTracker.configuration.ingestion.mode = :async
      LlmCostTracker.configuration.budgets.totals_source = :cache
      LlmCostTracker.configuration.budgets.monthly = 1_000
      allow(LlmCostTracker::Logging).to receive(:warn)
    end

    it "lands every storable row of a batch and fails only the row the database rejects" do
      good = Array.new(49) { track }
      bad = enqueue_unstorable_row
      good += Array.new(50) { track }

      expect(LlmCostTracker::Ingestion::Batch.new(identity: "worker-a").ingest).to eq(100)

      expect(LlmCostTracker::Call.where(event_id: good.map(&:event_id)).count).to eq(99)
      expect(inbox.pluck(:event_id)).to eq([bad.event_id])
      expect(inbox.first.last_error).to include("RangeError")
      expect(inbox.first.attempts).to eq(1)
      expect(LlmCostTracker::CallRollup.find_by!(period: "month").total_cost.to_d).to eq(BigDecimal("247.5"))
    end

    it "keeps the monthly budget total after the bad row is quarantined" do
      98.times { track }
      enqueue_unstorable_row
      track

      (max_attempts + 1).times { drain_cycle }

      expect(LlmCostTracker::Call.count).to eq(99)
      expect(inbox.quarantined.count).to eq(1)
      total = LlmCostTracker::Ledger::Period::Totals.call(%i[month], time: Time.now.utc).fetch(:month)
      expect(total).to eq(BigDecimal("247.5"))
    end

    it "retries a previously failed row on its own so it cannot fail a fresh batch again" do
      enqueue_unstorable_row
      drain_cycle
      fresh = Array.new(3) { track }
      calls = []
      allow(LlmCostTracker::Ledger::Store).to receive(:persist_records).and_wrap_original do |original, events|
        calls << events.size
        original.call(events)
      end

      drain_cycle

      expect(calls).to eq([3, 1])
      expect(LlmCostTracker::Call.where(event_id: fresh.map(&:event_id)).count).to eq(3)
      expect(inbox.first.attempts).to eq(2)
    end

    it "retries the whole batch without advancing attempts when the failure is transient" do
      3.times { track }
      calls = 0
      allow(LlmCostTracker::Ledger::Store).to receive(:persist_records) do
        calls += 1
        raise ActiveRecord::Deadlocked, "deadlock detected"
      end

      drain_cycle

      expect(calls).to eq(1)
      expect(inbox.pluck(:attempts)).to all(eq(0))
    end

    it "stops falling back on a transient error, keeps what landed, and does not count the attempt for the rest" do
      first = track
      bad = enqueue_unstorable_row
      after_bad = track
      last = track
      allow(LlmCostTracker::Ledger::Store).to receive(:persist_records).and_wrap_original do |original, events|
        raise ActiveRecord::Deadlocked, "deadlock detected" if events.map(&:event_id) == [after_bad.event_id]

        original.call(events)
      end

      allow(LlmCostTracker::Budget).to receive(:notify_persisted_safely!).and_call_original

      drain_cycle

      expect(LlmCostTracker::Call.pluck(:event_id)).to eq([first.event_id])
      expect(inbox.find_by!(event_id: bad.event_id).attempts).to eq(1)
      expect(inbox.where(event_id: [after_bad.event_id, last.event_id]).pluck(:attempts)).to eq([0, 0])
      expect(LlmCostTracker::CallRollup.find_by!(period: "month").total_cost.to_d).to eq(BigDecimal("2.5"))
      expect(LlmCostTracker::Budget).to have_received(:notify_persisted_safely!)
        .once.with(satisfy { |events| events.map(&:event_id) == [first.event_id] })
    end

    it "reports many rows the database rejects with a sample of their ids" do
      11.times { enqueue_unstorable_row }

      drain_cycle

      expect(inbox.where(attempts: 1).count).to eq(11)
      expect(LlmCostTracker::Logging).to have_received(:warn)
        .with(match(/11 inbox row\(s\) could not be stored .*\.\.\./))
    end

    it "fails a row whose duplicate the dedupe cannot resolve instead of retrying it in a loop" do
      track
      allow(LlmCostTracker::Ledger::Store).to receive(:persist_records)
        .and_raise(ActiveRecord::RecordNotUnique, "duplicate key value")

      drain_cycle

      expect(inbox.first.attempts).to eq(1)
      expect(inbox.first.last_error).to include("RecordNotUnique")
    end

    it "writes rows one at a time when the whole batch is too large for one statement" do
      events = Array.new(3) { track }
      allow(LlmCostTracker::Ledger::Store).to receive(:persist_records).and_wrap_original do |original, batch|
        raise ActiveRecord::ConnectionFailed, "TRILOGY_CLOSED_CONNECTION" if batch.size > 1

        original.call(batch)
      end

      drain_cycle

      expect(LlmCostTracker::Call.where(event_id: events.map(&:event_id)).count).to eq(3)
      expect(inbox.count).to eq(0)
    end

    it "stops at the first single-row statement timeout without counting the attempt" do
      Array.new(3) { track }
      calls = []
      allow(LlmCostTracker::Ledger::Store).to receive(:persist_records) do |batch|
        calls << batch.size
        raise ActiveRecord::QueryCanceled, "canceling statement due to statement timeout"
      end

      drain_cycle

      expect(calls).to eq([3, 1])
      expect(inbox.pluck(:attempts)).to all(eq(0))
    end

    it "treats a dropped connection as transient" do
      track
      allow(LlmCostTracker::Ledger::Store).to receive(:persist_records)
        .and_raise(ActiveRecord::ConnectionFailed, "PQconsumeInput() server closed the connection unexpectedly")

      drain_cycle

      expect(inbox.first.attempts).to eq(0)
    end

    it "deduplicates, isolates the bad row, and rolls up only fresh landed rows in one batch" do
      stale = track
      bad = enqueue_unstorable_row
      fresh = track
      stale_row = inbox.find_by!(event_id: stale.event_id)
      LlmCostTracker::Ledger::Store.insert([LlmCostTracker::Ingestion::Inbox.event_from_row(stale_row)])
      rollup_before = LlmCostTracker::CallRollup.find_by!(period: "month").total_cost.to_d

      drain_cycle

      expect(LlmCostTracker::Call.where(event_id: [stale.event_id, fresh.event_id]).count).to eq(2)
      expect(inbox.pluck(:event_id)).to eq([bad.event_id])
      expect(LlmCostTracker::CallRollup.find_by!(period: "month").total_cost.to_d - rollup_before)
        .to eq(BigDecimal("2.5"))
    end

    it "lands a NUL-byte row that an older release already wrote to the inbox" do
      event = track
      row = inbox.find_by!(event_id: event.event_id)
      payload = JSON.parse(row.payload)
      payload["tags"] = { "query" => "abc\u0000def" }
      payload["model"] = "gpt-4o\u0000"
      row.update!(payload: JSON.generate(payload))

      drain_cycle

      call = LlmCostTracker::Call.find_by!(event_id: event.event_id)
      expect(call.model).to eq("gpt-4o")
      expect(call.tag_pairs).to include("query" => "abcdef")
    end

    it "lands a row from an older release whose line item details key carries a NUL byte" do
      event = track(service_line_items: [{ dimension_key: "web_search_request", quantity: 1 }])
      row = inbox.find_by!(event_id: event.event_id)
      payload = JSON.parse(row.payload)
      payload["line_items"].last["details"] = { "no\u0000te" => "x" }
      row.update!(payload: JSON.generate(payload))

      drain_cycle

      call = LlmCostTracker::Call.find_by!(event_id: event.event_id)
      expect(LlmCostTracker::CallLineItem.where(llm_cost_tracker_call_id: call.id).pluck(:details)).to include("note" => "x")
    end

    it "enqueues and lands a tag value with invalid UTF-8 instead of raising from track" do
      event = track(tags: { query: "caf\xE9".b })
      drain_cycle

      expect(LlmCostTracker::Call.find_by!(event_id: event.event_id).tag_pairs).to include("query" => "caf�")
    end
  end
end
