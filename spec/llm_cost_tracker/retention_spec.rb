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
    end
    LlmCostTracker::LlmApiCall.reset_column_information
  end

  after do
    ActiveRecord::Base.connection.disconnect!
    LlmCostTracker::LlmApiCall.reset_column_information
  end

  def create_call(tracked_at:)
    LlmCostTracker::LlmApiCall.create!(
      provider: "openai", model: "gpt-4o",
      input_tokens: 0, output_tokens: 0, total_tokens: 0,
      tracked_at: tracked_at
    )
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

  it "raises on unsupported older_than type" do
    expect { described_class.prune(older_than: "forever") }.to raise_error(ArgumentError)
  end
end
