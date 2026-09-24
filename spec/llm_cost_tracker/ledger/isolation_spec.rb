# frozen_string_literal: true

require "spec_helper"
require "faraday"

RSpec.describe LlmCostTracker::Ledger::Isolation do
  deferred_rollups = ActiveRecord.gem_version >= Gem::Version.new("7.2")

  before do
    establish_database_connection!
    create_lct_tables!
    [LlmCostTracker::Call, LlmCostTracker::CallLineItem, LlmCostTracker::CallTag,
     LlmCostTracker::CallRollup].each(&:reset_column_information)
  end

  after { disconnect_database! }

  def build_event(event_id:, total_cost: 0.0025)
    LlmCostTracker::Event.new(
      event_id: event_id, provider: "openai", model: "gpt-4o",
      token_usage: LlmCostTracker::Usage::TokenUsage.build(input_tokens: 1_000, output_tokens: 0),
      pricing_mode: nil, cost: LlmCostTracker::Charges::Cost.new(components: {}, total: total_cost, currency: "USD"),
      tags: {}, latency_ms: nil, stream: false, usage_source: "manual", provider_response_id: nil,
      provider_project_id: nil, provider_api_key_id: nil, provider_workspace_id: nil, tracked_at: Time.now.utc,
      cost_status: LlmCostTracker::Charges::CostStatus::COMPLETE, pricing_snapshot: nil, line_items: []
    )
  end

  def postgresql?
    LlmCostTracker::Ledger::Schema::Adapter.postgresql?(ActiveRecord::Base.connection)
  end

  def host_transaction_usable?
    ActiveRecord::Base.connection.select_value("SELECT 1").to_i == 1
  end

  def monthly_rollup_total
    LlmCostTracker::CallRollup.where(period: "month").sum(:total_cost).to_d
  end

  def in_host_transaction_while_locked(lock_sql, **options)
    locked = Queue.new
    release = Queue.new
    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.transaction do
          connection.execute(lock_sql)
          locked << true
          release.pop
        end
      end
    end
    locked.pop

    ActiveRecord::Base.transaction(**options) do
      ActiveRecord::Base.connection.execute("SET LOCAL lock_timeout = '100ms'")
      yield
    ensure
      release << true
      holder.join
    end
  end

  def simulate_mysql_deadlock!
    connection = ActiveRecord::Base.connection
    connection.execute("DO $$ BEGIN RAISE EXCEPTION USING ERRCODE = '40P01', MESSAGE = 'Deadlock found'; END $$")
  rescue ActiveRecord::Deadlocked
    connection.raw_connection.exec("ROLLBACK")
    connection.raw_connection.exec("BEGIN")
    raise
  end

  it "runs the block directly outside a transaction" do
    expect(described_class.guard { :ran }).to eq(:ran)
  end

  it "keeps the host transaction usable when a ledger write fails inside it" do
    event = build_event(event_id: "duplicate")
    LlmCostTracker::Ledger::Store.insert(event)

    ActiveRecord::Base.transaction do
      expect { LlmCostTracker::Ledger::Store.insert(event) }.to raise_error(ActiveRecord::RecordNotUnique)
      expect(host_transaction_usable?).to be(true)
    end
    expect(LlmCostTracker::Call.count).to eq(1)
  end

  {
    "the period budget totals" => [
      "llm_cost_tracker_calls", -> { LlmCostTracker::Ledger::Period::Totals.call([:month], time: Time.now.utc) }
    ],
    "the per-tag budget spend" => [
      "llm_cost_tracker_call_tags",
      -> { LlmCostTracker::Budget::PerTag.spend_by_value("tenant_id", ["acme"], :daily, Time.now.utc.beginning_of_day) }
    ],
    "the batch de-duplication check" => [
      "llm_cost_tracker_calls",
      -> { LlmCostTracker::Call.already_recorded?(provider: "openai", provider_response_id: "resp_1") }
    ]
  }.each do |read, (table, query)|
    it "keeps the host transaction usable when #{read} read times out on a lock inside it" do
      skip "uses PostgreSQL LOCK TABLE and lock_timeout" unless postgresql?

      in_host_transaction_while_locked("LOCK TABLE #{table} IN ACCESS EXCLUSIVE MODE") do
        expect { query.call }.to raise_error(ActiveRecord::LockWaitTimeout)
        expect(host_transaction_usable?).to be(true)
      end
    end
  end

  it "keeps the host transaction usable when per-tag budgets are configured but the tag table is missing" do
    LlmCostTracker.configure { |config| config.budgets.per_tag = { tenant_id: { daily: 10 } } }
    ActiveRecord::Base.connection.drop_table(:llm_cost_tracker_call_tags, force: :cascade)
    LlmCostTracker::CallTag.reset_column_information
    allow(LlmCostTracker::Logging).to receive(:warn)

    ActiveRecord::Base.transaction do
      expect(LlmCostTracker::Budget::PerTag.active?).to be(false)
      expect(host_transaction_usable?).to be(true)
    end
    expect(LlmCostTracker::Logging).to have_received(:warn).with(/per-tag budgets are not enforced/)
  end

  it "returns the LLM response and keeps the host transaction usable when the ledger write fails" do
    ActiveRecord::Base.connection.drop_table(:llm_cost_tracker_call_tags, force: :cascade)
    body = { id: "chatcmpl_tx", model: "gpt-4o", choices: [],
             usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 } }.to_json
    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker, tags: { feature: "chat" }
      f.adapter(:test) { |stub| stub.post("/v1/chat/completions") { [200, { "Content-Type" => "application/json" }, body] } }
    end
    allow(LlmCostTracker::Logging).to receive(:warn)

    ActiveRecord::Base.transaction do
      expect(conn.post("/v1/chat/completions", { model: "gpt-4o" }.to_json).status).to eq(200)
      expect(host_transaction_usable?).to be(true)
    end
    expect(LlmCostTracker::Logging).to have_received(:warn).with(/Error processing response/)
  end

  it "returns the LLM response and records the call when the budget read after it times out inside the host transaction" do
    skip "uses PostgreSQL LOCK TABLE and lock_timeout" unless postgresql?
    LlmCostTracker.configuration.budgets.totals_source = :cache
    LlmCostTracker.configuration.budgets.monthly = 100
    body = { id: "chatcmpl_budget", model: "gpt-4o", choices: [],
             usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 } }.to_json
    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker
      f.adapter(:test) { |stub| stub.post("/v1/chat/completions") { [200, { "Content-Type" => "application/json" }, body] } }
    end
    allow(LlmCostTracker::Logging).to receive(:warn)
    LlmCostTracker::CallRollup.table_exists?

    in_host_transaction_while_locked("LOCK TABLE llm_cost_tracker_call_rollups IN ACCESS EXCLUSIVE MODE") do
      expect(conn.post("/v1/chat/completions", { model: "gpt-4o" }.to_json).status).to eq(200)
      expect(host_transaction_usable?).to be(true)
    end
    expect(LlmCostTracker::Call.count).to eq(1)
    expect(LlmCostTracker::Logging).to have_received(:warn).with(/Error processing response: ActiveRecord::LockWaitTimeout/)
  end

  it "commits both calls without retrying when the rollup row is locked during a call tracked inside a transaction" do
    skip "uses PostgreSQL lock_timeout" unless postgresql?
    LlmCostTracker.configuration.budgets.totals_source = :cache
    LlmCostTracker::Ledger::Store.insert(build_event(event_id: "seed"))
    allow(LlmCostTracker::Ledger::Rollups).to receive(:sleep)
    allow(LlmCostTracker::Logging).to receive(:warn)

    in_host_transaction_while_locked("UPDATE llm_cost_tracker_call_rollups SET total_cost = total_cost") do
      LlmCostTracker::Ledger::Store.insert(build_event(event_id: "in_transaction"))
      expect(host_transaction_usable?).to be(true)
    end
    expect(LlmCostTracker::Call.pluck(:event_id)).to contain_exactly("seed", "in_transaction")
    expect(LlmCostTracker::Ledger::Rollups).not_to have_received(:sleep)
  end

  it "makes a single rollup attempt inside a non-joinable transaction and logs the failure" do
    skip "uses PostgreSQL lock_timeout" unless postgresql?
    LlmCostTracker.configuration.budgets.totals_source = :cache
    LlmCostTracker::Ledger::Store.insert(build_event(event_id: "seed"))
    allow(LlmCostTracker::CallRollup).to receive(:increment_all).and_call_original
    allow(LlmCostTracker::Logging).to receive(:warn)

    in_host_transaction_while_locked("UPDATE llm_cost_tracker_call_rollups SET total_cost = total_cost",
                                     joinable: false) do
      LlmCostTracker::Ledger::Store.insert(build_event(event_id: "in_transaction"))
      expect(host_transaction_usable?).to be(true)
    end
    expect(LlmCostTracker::Call.pluck(:event_id)).to contain_exactly("seed", "in_transaction")
    expect(LlmCostTracker::CallRollup).to have_received(:increment_all).once
    expect(LlmCostTracker::Logging).to have_received(:warn).with(/Rollup increment failed .* after 1 attempt/)
  end

  it "increments rollups immediately inside a non-joinable transaction such as a test fixture" do
    LlmCostTracker.configuration.budgets.totals_source = :cache

    ActiveRecord::Base.transaction(joinable: false) do
      LlmCostTracker::Ledger::Store.insert(build_event(event_id: "fixture"))
      expect(monthly_rollup_total).to eq(BigDecimal("0.0025"))
    end
  end

  it "increments rollups immediately inside a joinable transaction on Rails 7.1", unless: deferred_rollups do
    LlmCostTracker.configuration.budgets.totals_source = :cache

    ActiveRecord::Base.transaction do
      LlmCostTracker::Ledger::Store.insert(build_event(event_id: "rails_71"))
      expect(monthly_rollup_total).to eq(BigDecimal("0.0025"))
    end
  end

  it "increments rollups once the host transaction commits and skips them when it rolls back", if: deferred_rollups do
    LlmCostTracker.configuration.budgets.totals_source = :cache

    ActiveRecord::Base.transaction do
      LlmCostTracker::Ledger::Store.insert(build_event(event_id: "committed"))
      expect(monthly_rollup_total).to eq(0)
    end
    expect(monthly_rollup_total).to eq(BigDecimal("0.0025"))

    ActiveRecord::Base.transaction do
      LlmCostTracker::Ledger::Store.insert(build_event(event_id: "rolled_back"))
      raise ActiveRecord::Rollback
    end
    expect(LlmCostTracker::Call.pluck(:event_id)).to eq(["committed"])
    expect(monthly_rollup_total).to eq(BigDecimal("0.0025"))
  end

  it "does not hold the rollup row lock for the rest of a host transaction", if: deferred_rollups do
    skip "uses a PostgreSQL lock_timeout" unless postgresql?
    LlmCostTracker.configuration.budgets.totals_source = :cache
    LlmCostTracker::Ledger::Store.insert(build_event(event_id: "seed"))
    recorded = Queue.new
    release = Queue.new

    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction do
          LlmCostTracker::Ledger::Store.insert(build_event(event_id: "holder"))
          recorded << true
          release.pop
        end
      end
    end
    recorded.pop

    other = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.execute("SET lock_timeout = '1s'")
        LlmCostTracker::Ledger::Store.insert(build_event(event_id: "other"))
      end
    end
    other.join
    expect(monthly_rollup_total).to eq(BigDecimal("0.005"))

    release << true
    holder.join
    expect(monthly_rollup_total).to eq(BigDecimal("0.0075"))
  end

  describe "on a database that rolls back the whole transaction on deadlock, like MySQL" do
    before do
      skip "simulates InnoDB deadlock semantics with PostgreSQL" unless postgresql?
      allow(ActiveRecord::Base.connection).to receive(:savepoint_errors_invalidate_transactions?).and_return(true)
      ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS lct_host_rows")
      ActiveRecord::Base.connection.execute("CREATE TABLE lct_host_rows (id serial primary key, note text)")
    end

    after { ActiveRecord::Base.connection.drop_table(:lct_host_rows, if_exists: true) }

    def host_notes
      ActiveRecord::Base.connection.select_values("SELECT note FROM lct_host_rows ORDER BY id")
    end

    it "raises TransactionAbortedError on a rollup deadlock instead of retrying outside the lost transaction" do
      LlmCostTracker.configuration.budgets.totals_source = :cache
      attempts = 0
      allow(LlmCostTracker::CallRollup).to receive(:increment_all) do
        attempts += 1
        simulate_mysql_deadlock!
      end

      expect do
        ActiveRecord::Base.transaction(joinable: false) do
          ActiveRecord::Base.connection.execute("INSERT INTO lct_host_rows (note) VALUES ('before')")
          LlmCostTracker::Ledger::Store.insert(build_event(event_id: "deadlocked"))
          ActiveRecord::Base.connection.execute("INSERT INTO lct_host_rows (note) VALUES ('after')")
        end
      end.to raise_error(LlmCostTracker::TransactionAbortedError, /Deadlocked/)

      expect(attempts).to eq(1)
      expect(host_notes).to be_empty
      expect(LlmCostTracker::Call.count).to eq(0)
      expect(monthly_rollup_total).to eq(0)
    end

    it "raises TransactionAbortedError on a ledger write deadlock" do
      allow(LlmCostTracker::Call).to receive(:insert_all!) { simulate_mysql_deadlock! }

      expect do
        ActiveRecord::Base.transaction do
          ActiveRecord::Base.connection.execute("INSERT INTO lct_host_rows (note) VALUES ('before')")
          LlmCostTracker::Ledger::Store.insert(build_event(event_id: "deadlocked"))
          ActiveRecord::Base.connection.execute("INSERT INTO lct_host_rows (note) VALUES ('after')")
        end
      end.to raise_error(LlmCostTracker::TransactionAbortedError, /Deadlocked/)

      expect(host_notes).to be_empty
      expect(LlmCostTracker::Call.count).to eq(0)
    end
  end
end
