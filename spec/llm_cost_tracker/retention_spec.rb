# frozen_string_literal: true

require "spec_helper"
require "active_record"
require "llm_cost_tracker/ledger"

RSpec.describe LlmCostTracker::Retention do
  before do
    establish_database_connection!
    create_lct_tables!
    LlmCostTracker::Call.reset_column_information
    LlmCostTracker::ServiceCharge.reset_column_information
    LlmCostTracker::CallRollup.reset_column_information
  end

  after do
    disconnect_database!
    LlmCostTracker::Call.reset_column_information
    LlmCostTracker::ServiceCharge.reset_column_information
  end

  def create_call(tracked_at:, total_cost: nil)
    LlmCostTracker::Call.create!(
      provider: "openai", model: "gpt-4o",
      input_tokens: 0, output_tokens: 0, total_tokens: 0,
      total_cost: total_cost,
      cost_status: total_cost.nil? ? LlmCostTracker::Billing::CostStatus::UNKNOWN : LlmCostTracker::Billing::CostStatus::COMPLETE,
      tags: tags_for_database({}),
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
    expect(LlmCostTracker::Call.count).to eq(1)
  end

  it "accepts integer days" do
    now = Time.utc(2026, 4, 20, 12, 0, 0)
    create_call(tracked_at: now - 100.days)

    expect { described_class.prune(older_than: 30, now: now) }
      .to change(LlmCostTracker::Call, :count).from(1).to(0)
  end

  it "batches deletes across the cutoff" do
    now = Time.utc(2026, 4, 20, 12, 0, 0)
    5.times { create_call(tracked_at: now - 200.days) }

    deleted = described_class.prune(older_than: 90.days, batch_size: 2, now: now)

    expect(deleted).to eq(5)
    expect(LlmCostTracker::Call.count).to eq(0)
  end

  it "keeps active call rollups in sync when pruning inside the current window" do
    now = Time.utc(2026, 4, 20, 12, 0, 0)
    create_call(tracked_at: Time.utc(2026, 4, 20, 8, 0, 0), total_cost: 2.0)
    create_call(tracked_at: Time.utc(2026, 4, 20, 11, 0, 0), total_cost: 3.0)
    LlmCostTracker::CallRollup.create!(period: "day", period_start: Date.new(2026, 4, 20), total_cost: 5.0)
    LlmCostTracker::CallRollup.create!(period: "month", period_start: Date.new(2026, 4, 1), total_cost: 5.0)

    deleted = described_class.prune(older_than: Time.utc(2026, 4, 20, 10, 0, 0), now: now)

    expect(deleted).to eq(1)
    expect(LlmCostTracker::Call.count).to eq(1)
    expect(LlmCostTracker::CallRollup.find_by!(period: "day").total_cost.to_f).to eq(3.0)
    expect(LlmCostTracker::CallRollup.find_by!(period: "month").total_cost.to_f).to eq(3.0)
  end

  it "deletes service charges with pruned parent calls" do
    now = Time.utc(2026, 4, 20, 12, 0, 0)
    old_call = create_call(tracked_at: now - 100.days, total_cost: 0.01)
    create_call(tracked_at: now - 1.day, total_cost: 0.01)
    LlmCostTracker::ServiceCharge.create!(
      llm_cost_tracker_call_id: old_call.id,
      charge_id: "old-charge",
      component: "web_search_request",
      unit: "request",
      quantity: 1,
      rate_quantity: 1,
      currency: "USD",
      cost_status: LlmCostTracker::Billing::CostStatus::UNKNOWN,
      details: {}
    )

    described_class.prune(older_than: 90.days, now: now)

    expect(LlmCostTracker::ServiceCharge.where(charge_id: "old-charge")).to be_empty
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
