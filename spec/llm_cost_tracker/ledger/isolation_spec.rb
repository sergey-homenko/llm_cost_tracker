# frozen_string_literal: true

require "spec_helper"
require "faraday"

RSpec.describe LlmCostTracker::Ledger::Isolation do
  deferred_rollups = ActiveRecord.respond_to?(:after_all_transactions_commit)

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

  def host_transaction_usable?
    ActiveRecord::Base.connection.select_value("SELECT 1").to_i == 1
  end

  def monthly_rollup_total
    LlmCostTracker::CallRollup.where(period: "month").sum(:total_cost).to_d
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

  it "keeps the host transaction usable when a guarded read fails inside it" do
    ActiveRecord::Base.transaction do
      expect { described_class.guard { ActiveRecord::Base.connection.select_value("SELECT * FROM lct_no_such_table") } }
        .to raise_error(ActiveRecord::StatementInvalid)
      expect(host_transaction_usable?).to be(true)
    end
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
    skip "uses a PostgreSQL lock_timeout" unless LlmCostTracker::Ledger::Schema::Adapter.postgresql?(ActiveRecord::Base.connection)
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
end
