# frozen_string_literal: true

require "spec_helper"
require "active_record"
require "llm_cost_tracker/llm_api_call"

RSpec.describe LlmCostTracker::Retention do
  before do
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table :llm_api_calls do |t|
        t.string :provider, null: false
        t.string :model, null: false
        t.integer :input_tokens, null: false, default: 0
        t.integer :output_tokens, null: false, default: 0
        t.integer :total_tokens, null: false, default: 0
        t.decimal :input_cost, precision: 20, scale: 8
        t.decimal :output_cost, precision: 20, scale: 8
        t.decimal :total_cost, precision: 20, scale: 8
        t.integer :latency_ms
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

      add_index :llm_cost_tracker_period_totals, %i[period period_start], unique: true
    end
    LlmCostTracker::LlmApiCall.reset_column_information
    LlmCostTracker::PeriodTotal.reset_column_information if defined?(LlmCostTracker::PeriodTotal)
    LlmCostTracker::Storage::ActiveRecordStore.reset! if defined?(LlmCostTracker::Storage::ActiveRecordStore)
  end

  after do
    ActiveRecord::Base.connection.disconnect!
    LlmCostTracker::LlmApiCall.reset_column_information
    LlmCostTracker::Storage::ActiveRecordStore.reset! if defined?(LlmCostTracker::Storage::ActiveRecordStore)
  end

  def create_call(tracked_at:, total_cost: nil)
    LlmCostTracker::LlmApiCall.create!(
      provider: "openai", model: "gpt-4o",
      input_tokens: 0, output_tokens: 0, total_tokens: 0,
      total_cost: total_cost,
      tracked_at: tracked_at
    )
  end

  def period_total_model
    require "llm_cost_tracker/period_total" unless defined?(LlmCostTracker::PeriodTotal)

    LlmCostTracker::PeriodTotal
  end

  it "deletes rows older than the given duration and keeps newer ones" do
    now = Time.utc(2026, 4, 20, 12, 0, 0)
    create_call(tracked_at: now - 100.days)
    create_call(tracked_at: now - 91.days)
    create_call(tracked_at: now - 1.day)

    deleted = described_class.prune(older_than: 90.days, now: now)

    expect(deleted).to eq(2)
    expect(LlmCostTracker::LlmApiCall.count).to eq(1)
  end

  it "accepts integer days" do
    now = Time.utc(2026, 4, 20, 12, 0, 0)
    create_call(tracked_at: now - 100.days)

    expect { described_class.prune(older_than: 30, now: now) }
      .to change(LlmCostTracker::LlmApiCall, :count).from(1).to(0)
  end

  it "batches deletes across the cutoff" do
    now = Time.utc(2026, 4, 20, 12, 0, 0)
    5.times { create_call(tracked_at: now - 200.days) }

    deleted = described_class.prune(older_than: 90.days, batch_size: 2, now: now)

    expect(deleted).to eq(5)
    expect(LlmCostTracker::LlmApiCall.count).to eq(0)
  end

  it "keeps active period rollups in sync when pruning inside the current window" do
    now = Time.utc(2026, 4, 20, 12, 0, 0)
    create_call(tracked_at: Time.utc(2026, 4, 20, 8, 0, 0), total_cost: 2.0)
    create_call(tracked_at: Time.utc(2026, 4, 20, 11, 0, 0), total_cost: 3.0)
    period_total_model.create!(period: "day", period_start: Date.new(2026, 4, 20), total_cost: 5.0)
    period_total_model.create!(period: "month", period_start: Date.new(2026, 4, 1), total_cost: 5.0)

    deleted = described_class.prune(older_than: Time.utc(2026, 4, 20, 10, 0, 0), now: now)

    expect(deleted).to eq(1)
    expect(LlmCostTracker::LlmApiCall.count).to eq(1)
    expect(period_total_model.find_by!(period: "day").total_cost.to_f).to eq(3.0)
    expect(period_total_model.find_by!(period: "month").total_cost.to_f).to eq(3.0)
  end

  it "raises on unsupported older_than type" do
    expect { described_class.prune(older_than: "forever") }.to raise_error(ArgumentError)
  end

  it "rejects non-positive integer day cutoffs" do
    expect { described_class.prune(older_than: 0) }.to raise_error(ArgumentError, /days must be positive/)
    expect { described_class.prune(older_than: -1) }.to raise_error(ArgumentError, /days must be positive/)
  end

  it "rejects non-positive batch sizes" do
    expect { described_class.prune(older_than: 30, batch_size: 0) }
      .to raise_error(ArgumentError, /batch_size must be positive/)
  end

  it "rejects absolute cutoffs that are not before now" do
    now = Time.utc(2026, 4, 20, 12, 0, 0)

    expect { described_class.prune(older_than: now, now: now) }
      .to raise_error(ArgumentError, /cutoff must be before now/)
  end
end
