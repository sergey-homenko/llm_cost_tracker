# frozen_string_literal: true

require "spec_helper"

require_relative "../../dummy/config/environment"

RSpec.describe LlmCostTracker::Ledger::Rollups do
  include_context "with mounted llm cost tracker engine"

  def build_event(total_cost:, currency: "USD", tracked_at: Time.now.utc)
    LlmCostTracker::Event.new(
      event_id: SecureRandom.uuid,
      provider: "openai",
      model: "gpt-4o",
      token_usage: LlmCostTracker::Usage::TokenUsage.build(input_tokens: 1, output_tokens: 1),
      pricing_mode: nil,
      cost: LlmCostTracker::Charges::Cost.new(components: {}, total: total_cost, currency: currency),
      tags: {},
      latency_ms: nil,
      stream: false,
      usage_source: "response",
      provider_response_id: nil,
      provider_project_id: nil,
      provider_api_key_id: nil,
      provider_workspace_id: nil,
      tracked_at: tracked_at,
      cost_status: LlmCostTracker::Charges::CostStatus::COMPLETE,
      pricing_snapshot: { "currency" => currency },
      line_items: []
    )
  end

  describe ".increment!" do
    it "writes a separate rollup row per currency" do
      time = Time.utc(2026, 5, 7, 12)
      described_class.increment!([build_event(total_cost: 1.5, currency: "USD", tracked_at: time)])
      described_class.increment!([build_event(total_cost: 2.0, currency: "EUR", tracked_at: time)])

      rollups = LlmCostTracker::CallRollup.where(period: "month").order(:currency).pluck(:currency, :total_cost)

      expect(rollups).to eq([["EUR", 2.0], ["USD", 1.5]])
    end

    it "falls back to USD when the pricing snapshot has no currency" do
      time = Time.utc(2026, 5, 7, 12)
      event = build_event(total_cost: 1.0, tracked_at: time)
      event = event.with(pricing_snapshot: nil)

      described_class.increment!([event])

      rollup = LlmCostTracker::CallRollup.find_by(period: "month")
      expect(rollup.currency).to eq("USD")
    end
  end

  describe ".decrement!" do
    it "scopes the deduction to the snapshot currency, leaving other currency rows untouched" do
      time = Time.utc(2026, 5, 7, 12)
      described_class.increment!([build_event(total_cost: 5.0, currency: "USD", tracked_at: time)])
      described_class.increment!([build_event(total_cost: 3.0, currency: "EUR", tracked_at: time)])

      record = Struct.new(:tracked_at, :total_cost, :pricing_snapshot, :provider)
                     .new(time, BigDecimal("3.0"), { "currency" => "EUR" }, "openai")
      described_class.decrement!([record])

      remaining = LlmCostTracker::CallRollup.where(period: "month").order(:currency).pluck(:currency, :total_cost)
      expect(remaining).to eq([["EUR", 0.0], ["USD", 5.0]])
    end
  end

  describe "with cache_rollups enabled but the rollups table missing" do
    before do
      LlmCostTracker.configure { |config| config.budgets.totals_source = :cache }
      LlmCostTracker::Ledger::Store.insert([build_event(total_cost: 4.5, tracked_at: Time.utc(2026, 5, 7, 12))])
      ActiveRecord::Base.connection.drop_table(:llm_cost_tracker_call_rollups, if_exists: true)
      LlmCostTracker::CallRollup.reset_column_information
    end

    it "aggregates budget totals from calls instead of raising" do
      time = Time.utc(2026, 5, 7, 12)

      totals = LlmCostTracker::Ledger::Period::Totals.call(%i[day month], time: time)

      expect(totals[:day]).to be_within(0.0001).of(4.5)
      expect(totals[:month]).to be_within(0.0001).of(4.5)
    end

    it "warns once that the fast path is unavailable" do
      logged = []
      allow(LlmCostTracker::Logging).to receive(:warn) { |message| logged << message }

      2.times { LlmCostTracker::Ledger::Period::Totals.call(%i[day], time: Time.utc(2026, 5, 7, 12)) }

      expect(logged.size).to eq(1)
      expect(logged.first).to include("llm_cost_tracker_call_rollups is missing")
    end

    it "increments the table once another process creates it" do
      migrator = Class.new(ActiveRecord::Base) do
        self.abstract_class = true
        def self.name = "RollupsMigrator"
      end
      migrator.establish_connection(ActiveRecord::Base.connection_db_config)
      expect(described_class.cache_active?).to be(false)

      create_call_rollups_table(migrator.connection)
      migrator.connection.add_index :llm_cost_tracker_call_rollups, %i[period period_start currency provider],
                                    unique: true
      migrator.remove_connection
      described_class.increment!([build_event(total_cost: 2.0, tracked_at: Time.utc(2026, 5, 8, 12))])

      expect(LlmCostTracker::CallRollup.where(period: "day").sum(:total_cost)).to eq(2.0)
    end
  end

  describe "with cache_rollups disabled" do
    it "writes no rollup rows on increment!" do
      LlmCostTracker.configuration.budgets.totals_source = :ledger

      described_class.increment!([build_event(total_cost: 1.5)])

      expect(LlmCostTracker::CallRollup.count).to eq(0)
    end

    it "leaves rollup rows untouched on decrement!" do
      time = Time.utc(2026, 5, 7, 12)
      described_class.increment!([build_event(total_cost: 5.0, tracked_at: time)])
      LlmCostTracker.configuration.budgets.totals_source = :ledger

      record = Struct.new(:tracked_at, :total_cost, :pricing_snapshot, :provider)
                     .new(time, BigDecimal("5.0"), { "currency" => "USD" }, "openai")
      described_class.decrement!([record])

      expect(LlmCostTracker::CallRollup.where(period: "month").pluck(:total_cost)).to eq([5.0])
    end
  end

  describe "Period::Totals integration" do
    it "sums rollups across all currencies when cache_rollups is enabled" do
      LlmCostTracker.configure { |config| config.budgets.totals_source = :cache }
      time = Time.utc(2026, 5, 7, 12)
      described_class.increment!([build_event(total_cost: 4.5, currency: "USD", tracked_at: time - 86_400)])
      described_class.increment!([build_event(total_cost: 99.0, currency: "EUR", tracked_at: time - 86_400)])

      totals = LlmCostTracker::Ledger::Period::Totals.call(%i[day month], time: time)

      expect(totals[:day]).to eq(0)
      expect(totals[:month]).to be_within(0.0001).of(103.5)
    end

    it "reads completed days from the day rollups and only today's calls from the ledger" do
      LlmCostTracker.configure { |config| config.budgets.totals_source = :cache }
      time = Time.utc(2026, 5, 15, 12)
      LlmCostTracker::Ledger::Store.insert([build_event(total_cost: 4.0, tracked_at: Time.utc(2026, 5, 3, 9)),
                                            build_event(total_cost: 1.5, tracked_at: time - 60),
                                            build_event(total_cost: 7.0, tracked_at: time + 60)])
      statements = []
      totals = ActiveSupport::Notifications.subscribed(->(*, payload) { statements << payload[:sql] },
                                                       "sql.active_record") do
        LlmCostTracker::Ledger::Period::Totals.call(%i[day month], time: time)
      end
      month_scan = LlmCostTracker::Call.between(Time.utc(2026, 5, 1), time).to_sql.split("WHERE").last

      expect(totals).to eq(day: 1.5, month: 5.5)
      expect(statements.join).not_to include(month_scan)
    end

    %i[inline async].each do |mode|
      it "fires the monthly budget once, on the call that crosses it on a later day, with #{mode} ingestion" do
        notified = []
        LlmCostTracker.configure do |config|
          config.ingestion.mode = mode
          config.budgets.totals_source = :cache
          config.budgets.monthly = 10
          config.budgets.on_exceeded = ->(payload) { notified << payload[:total] }
          config.pricing.overrides = { "budget-model" => { input: 3.0 } }
        end

        [Time.utc(2026, 5, 3, 9), Time.utc(2026, 5, 14, 9), Time.utc(2026, 5, 15, 9), Time.utc(2026, 5, 15, 10)]
          .each do |time|
            travel_to(time) do
              LlmCostTracker.track(provider: "custom", model: "budget-model", tokens: { input_tokens: 1_000_000 })
              LlmCostTracker::Ingestion::Worker.flush! if mode == :async
            end
          end

        expect(notified).to eq([12])
      end
    end

    it "counts calls recorded before the switch to :cache once rebuild_rollups runs after it" do
      month = -> { LlmCostTracker::Ledger::Period::Totals.call(%i[month], time: Time.utc(2026, 5, 15, 12))[:month] }
      LlmCostTracker.configuration.budgets.totals_source = :ledger
      LlmCostTracker::Ledger::Store.insert([build_event(total_cost: 3.0, tracked_at: Time.utc(2026, 5, 3, 9))])
      LlmCostTracker.configuration.budgets.totals_source = :cache
      LlmCostTracker::Ledger::Store.insert([build_event(total_cost: 3.0, tracked_at: Time.utc(2026, 5, 14, 9))])
      before_rebuild = month.call
      described_class.rebuild!

      expect([before_rebuild, month.call]).to eq([3, 6])
    end

    it "reads today's calls live even when the rollups table has been truncated" do
      LlmCostTracker.configure { |config| config.budgets.totals_source = :cache }
      time = Time.utc(2026, 5, 7, 12)
      LlmCostTracker::Ledger::Store.insert([
                                                  build_event(total_cost: 4.5, currency: "USD", tracked_at: time),
                                                  build_event(total_cost: 99.0, currency: "EUR", tracked_at: time)
                                                ])
      LlmCostTracker::CallRollup.delete_all

      totals = LlmCostTracker::Ledger::Period::Totals.call(%i[day month], time: time)

      expect(totals[:day]).to be_within(0.0001).of(103.5)
      expect(totals[:month]).to be_within(0.0001).of(103.5)
    end

    it "reads today's calls live, ignoring a stale month rollup row" do
      LlmCostTracker.configure { |config| config.budgets.totals_source = :cache }
      time = Time.utc(2026, 5, 15, 12)
      LlmCostTracker::Ledger::Store.insert([
                                                  build_event(total_cost: 50.0, currency: "USD", tracked_at: time),
                                                  build_event(total_cost: 50.0, currency: "USD", tracked_at: time)
                                                ])
      LlmCostTracker::CallRollup.where(period: "month").update_all(total_cost: 5.0)

      totals = LlmCostTracker::Ledger::Period::Totals.call(%i[month], time: time)

      expect(totals[:month]).to be_within(0.0001).of(100.0)
    end
  end

  describe ".rebuild!" do
    def seed_call(total_cost:, provider: "openai", currency: "USD", tracked_at: Time.utc(2026, 5, 7, 12))
      LlmCostTracker::Call.create!(
        event_id: SecureRandom.uuid, provider: provider, model: "gpt-4o",
        input_tokens: 0, output_tokens: 0, total_tokens: 0,
        total_cost: total_cost,
        cost_status: LlmCostTracker::Charges::CostStatus::COMPLETE,
        pricing_snapshot: { "currency" => currency },
        tracked_at: tracked_at
      )
    end

    it "reprojects rollup totals from the calls ledger per period, currency, and provider" do
      seed_call(total_cost: 1.5, currency: "USD")
      seed_call(total_cost: 2.0, currency: "USD")
      seed_call(total_cost: 3.0, currency: "EUR")
      seed_call(total_cost: 0.5, provider: "anthropic", currency: "USD")

      rows_written = described_class.rebuild!

      expect(LlmCostTracker::CallRollup.find_by(period: "month", provider: "openai", currency: "USD").total_cost).to eq(3.5)
      expect(LlmCostTracker::CallRollup.find_by(period: "month", provider: "openai", currency: "EUR").total_cost).to eq(3.0)
      expect(LlmCostTracker::CallRollup.find_by(period: "month", provider: "anthropic", currency: "USD").total_cost).to eq(0.5)
      expect(rows_written).to eq(LlmCostTracker::CallRollup.count)
    end

    it "produces the same rows incremental increment! would have written" do
      time = Time.utc(2026, 5, 7, 12)
      described_class.increment!([
                                   build_event(total_cost: 1.5, currency: "USD", tracked_at: time),
                                   build_event(total_cost: 2.0, currency: "EUR", tracked_at: time)
                                 ])
      incremental = LlmCostTracker::CallRollup.order(:period, :currency).pluck(:period, :period_start, :currency, :provider, :total_cost)

      LlmCostTracker::CallRollup.delete_all
      seed_call(total_cost: 1.5, currency: "USD", tracked_at: time)
      seed_call(total_cost: 2.0, currency: "EUR", tracked_at: time)
      described_class.rebuild!

      rebuilt = LlmCostTracker::CallRollup.order(:period, :currency).pluck(:period, :period_start, :currency, :provider, :total_cost)
      expect(rebuilt).to eq(incremental)
    end

    it "resyncs drifted rollup totals back to the ledger truth" do
      seed_call(total_cost: 4.0, currency: "USD")
      described_class.rebuild!
      LlmCostTracker::CallRollup.update_all(total_cost: 999.0)

      described_class.rebuild!

      expect(LlmCostTracker::CallRollup.where(total_cost: 999.0)).to be_empty
      expect(LlmCostTracker::CallRollup.find_by(period: "month").total_cost).to eq(4.0)
    end

    it "writes no rollup rows when no call has a cost" do
      seed_call(total_cost: nil)
      expect(described_class.rebuild!).to eq(0)
      expect(LlmCostTracker::CallRollup.count).to eq(0)
    end

    it "still rebuilds while cache_rollups is disabled, so the table can be primed before opting in" do
      seed_call(total_cost: 4.5, currency: "USD")
      LlmCostTracker.configuration.budgets.totals_source = :ledger

      expect(described_class.rebuild!).to eq(LlmCostTracker::CallRollup.count)
      expect(LlmCostTracker::CallRollup.find_by(period: "month").total_cost).to eq(4.5)
    end
  end
end
