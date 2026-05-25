# frozen_string_literal: true

require "spec_helper"
require "active_record"
require "active_support/notifications"
require "llm_cost_tracker/ledger"

ENV["RAILS_ENV"] ||= "test"

require_relative "../../dummy/config/environment"

RSpec.describe "LlmCostTracker dashboard services" do
  def reset_database!
    establish_database_connection!

    create_lct_tables!

    LlmCostTracker::Call.reset_column_information
    LlmCostTracker::CallLineItem.reset_column_information
    LlmCostTracker::CallTag.reset_column_information
    LlmCostTracker::CallRollup.reset_column_information
    LlmCostTracker::Ingestion::InboxEntry.reset_column_information
    LlmCostTracker::Ingestion::Lease.reset_column_information
  end

  def create_call(**overrides)
    attrs = call_defaults.merge(overrides)
    attrs[:total_tokens] = total_tokens_for(attrs)
    raw_tags = attrs.delete(:tags)

    call = LlmCostTracker::Call.create!(attrs)
    create_call_tag_rows(call, raw_tags)
    LlmCostTracker::Ledger::Rollups.increment!([call])
    call
  end

  let(:call_defaults) do
    {
      provider: "openai",
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      cache_read_input_tokens: 0,
      cache_write_input_tokens: 0,
      cache_write_extended_input_tokens: 0,
      audio_input_tokens: 0,
      hidden_output_tokens: 0,
      audio_output_tokens: 0,
      total_cost: 1.0,
      cost_status: LlmCostTracker::Billing::CostStatus::COMPLETE,
      latency_ms: 100,
      stream: false,
      usage_source: nil,
      provider_response_id: nil,
      pricing_mode: nil,
      tags: {},
      tracked_at: Time.utc(2026, 4, 18, 12)
    }
  end

  def total_tokens_for(attrs)
    attrs.fetch(:input_tokens) +
      attrs.fetch(:cache_read_input_tokens) +
      attrs.fetch(:cache_write_input_tokens) +
      attrs.fetch(:cache_write_extended_input_tokens) +
      attrs.fetch(:audio_input_tokens) +
      attrs.fetch(:output_tokens) +
      attrs.fetch(:audio_output_tokens)
  end

  def capture_llm_cost_tracker_call_selects
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s
      next if payload[:name] == "SCHEMA"
      next unless sql.match?(/\ASELECT/i)
      next unless sql.include?("llm_cost_tracker_calls")

      statements << sql
    end

    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  before do
    reset_database!
  end

  after do
    disconnect_database!
  end

  describe LlmCostTracker::Dashboard::Pagination do
    it "uses defaults for nil params" do
      page = described_class.call(nil)

      expect(page.page).to eq(1)
      expect(page.per).to eq(50)
      expect(page.offset).to eq(0)
    end

    it "normalizes invalid pagination params" do
      page = described_class.call("page" => "-1", "per" => "10000")

      expect(page.page).to eq(1)
      expect(page.per).to eq(200)
      expect(page.offset).to eq(0)
      expect(page.prev_page?).to be false
    end

    it "uses defaults for unsupported param objects" do
      page = described_class.call(Object.new)

      expect(page.page).to eq(1)
      expect(page.per).to eq(50)
    end

    it "calculates offsets and next-page state" do
      page = described_class.call(page: "3", per: "50")

      expect(page.offset).to eq(100)
      expect(page.prev_page?).to be true
      expect(page.next_page?(151)).to be true
      expect(page.next_page?(150)).to be false
      expect(page.total_pages(151)).to eq(4)
      expect(page.total_pages(0)).to eq(1)
    end
  end

  describe LlmCostTracker::Dashboard::Params do
    it "normalizes tag query params and drops blank tag pairs" do
      tags = described_class.tag_query("feature" => "chat", "" => "missing", "team" => "")

      expect(tags).to eq("feature" => "chat")
    end
  end

  describe LlmCostTracker::Dashboard::DateRange do
    it "defaults to the latest thirty days" do
      range = described_class.call(params: {}, today: Date.new(2026, 4, 20))

      expect(range.from).to eq(Date.new(2026, 3, 22))
      expect(range.to).to eq(Date.new(2026, 4, 20))
    end

    it "uses provided iso8601 dates" do
      range = described_class.call(
        params: { from: "2026-04-01", to: "2026-04-18" },
        today: Date.new(2026, 4, 20)
      )

      expect(range.from).to eq(Date.new(2026, 4, 1))
      expect(range.to).to eq(Date.new(2026, 4, 18))
    end

    it "rejects reversed ranges" do
      expect do
        described_class.call(params: { from: "2026-04-20", to: "2026-04-18" })
      end.to raise_error(LlmCostTracker::InvalidFilterError, /from date must be/)
    end

    it "rejects ranges over the dashboard cap" do
      expect do
        described_class.call(params: { from: "2025-01-01", to: "2026-04-20" })
      end.to raise_error(LlmCostTracker::InvalidFilterError, /date range cannot exceed/)
    end
  end

  describe LlmCostTracker::Dashboard::Filter do
    around { |example| travel_to(Time.utc(2026, 4, 19, 12)) { example.run } }

    it "filters by dates, provider, model, and multiple tag keys" do
      create_call(
        provider: "openai",
        model: "gpt-4o",
        tags: { "feature" => "chat", "user_id" => "42" },
        tracked_at: Time.utc(2026, 4, 18, 12)
      )
      create_call(
        provider: "openai",
        model: "gpt-4o-mini",
        tags: { "feature" => "chat", "user_id" => "42" },
        tracked_at: Time.utc(2026, 4, 18, 12)
      )
      create_call(
        provider: "anthropic",
        model: "claude-haiku-4-5",
        tags: { "feature" => "chat", "user_id" => "42" },
        tracked_at: Time.utc(2026, 4, 18, 12)
      )

      relation = described_class.call(
        params: {
          "from" => "2026-04-18",
          "to" => "2026-04-18",
          "provider" => "openai",
          "model" => "gpt-4o",
          "tag" => { "feature" => "chat", "user_id" => "42" }
        }
      )

      expect(relation.count).to eq(1)
      expect(relation.first.model).to eq("gpt-4o")
    end

    it "ignores invalid dates" do
      create_call(tracked_at: Time.utc(2026, 4, 18, 12))

      relation = described_class.call(params: { from: "not-a-date", to: "also-bad" })

      expect(relation.count).to eq(1)
    end

    it "rejects reversed date ranges" do
      expect do
        described_class.call(params: { from: "2026-04-20", to: "2026-04-18" }).load
      end.to raise_error(LlmCostTracker::InvalidFilterError, /from date must be/)
    end

    it "rejects oversized date ranges" do
      expect do
        described_class.call(params: { from: "2025-01-01", to: "2026-04-20" }).load
      end.to raise_error(LlmCostTracker::InvalidFilterError, /date range cannot exceed/)
    end

    it "rejects one-sided date ranges" do
      expect do
        described_class.call(params: { from: "2026-04-18" }).load
      end.to raise_error(LlmCostTracker::InvalidFilterError, /from and to dates/)

      expect do
        described_class.call(params: { to: "2026-04-18" }).load
      end.to raise_error(LlmCostTracker::InvalidFilterError, /from and to dates/)
    end

    it "returns the original scope for unsupported param objects" do
      create_call(model: "gpt-4o")

      relation = described_class.call(params: Object.new)

      expect(relation.count).to eq(1)
      expect(relation.first.model).to eq("gpt-4o")
    end

    it "ignores malformed non-hash tag params" do
      create_call(tags: { feature: "chat" })

      relation = described_class.call(params: { tag: "malformed" })

      expect(relation.count).to eq(1)
    end

    it "filters by a single tag key from the tag hash" do
      create_call(model: "chat-model", tags: { feature: "chat" })
      create_call(model: "summary-model", tags: { feature: "summarizer" })

      relation = described_class.call(params: { tag: { feature: "summarizer" } })

      expect(relation.pluck(:model)).to eq(["summary-model"])
    end

    it "raises an invalid filter error for unsafe tag keys" do
      expect do
        described_class.call(params: { tag: { ";DROP TABLE" => "x" } })
      end.to raise_error(LlmCostTracker::InvalidFilterError, /invalid tag key/)
    end

    it "narrows to streaming calls when stream=yes" do
      create_call(model: "stream-model", stream: true, usage_source: "stream_final")
      create_call(model: "sync-model",   stream: false, usage_source: "response")

      relation = described_class.call(params: { stream: "yes" })

      expect(relation.pluck(:model)).to eq(["stream-model"])
    end

    it "narrows to non-streaming calls when stream=no" do
      create_call(model: "stream-model", stream: true)
      create_call(model: "sync-model",   stream: false)

      relation = described_class.call(params: { stream: "no" })

      expect(relation.pluck(:model)).to eq(["sync-model"])
    end

    it "filters by usage_source value" do
      create_call(model: "a", stream: true,  usage_source: "stream_final")
      create_call(model: "b", stream: true,  usage_source: "unknown")
      create_call(model: "c", stream: false, usage_source: "response")

      relation = described_class.call(params: { usage_source: "unknown" })

      expect(relation.pluck(:model)).to eq(["b"])
    end
  end

  describe LlmCostTracker::Dashboard::TimeSeries do
    it "returns zero-filled day points for an empty scope" do
      points = described_class.call(
        from: Date.new(2026, 4, 1),
        to: Date.new(2026, 4, 3)
      )

      expect(points).to eq(
        [
          { label: "2026-04-01", cost: 0.0 },
          { label: "2026-04-02", cost: 0.0 },
          { label: "2026-04-03", cost: 0.0 }
        ]
      )
    end

    it "fills missing days around recorded costs" do
      create_call(total_cost: 2.5, tracked_at: Time.utc(2026, 4, 2, 12))

      points = described_class.call(
        from: Date.new(2026, 4, 1),
        to: Date.new(2026, 4, 3)
      )

      expect(points).to eq(
        [
          { label: "2026-04-01", cost: 0.0 },
          { label: "2026-04-02", cost: 2.5 },
          { label: "2026-04-03", cost: 0.0 }
        ]
      )
    end
  end

  describe LlmCostTracker::Dashboard::OverviewStats do
    it "returns zero values for an empty scope" do
      stats = described_class.call

      expect(stats.total_cost.to_f).to eq(0.0)
      expect(stats.total_calls.to_i).to eq(0)
      expect(stats.average_cost_per_call.to_f).to eq(0.0)
      expect(stats.average_latency_ms).to be_nil
    end

    it "aggregates total cost, calls, average cost, and latency" do
      create_call(total_cost: 2.0, latency_ms: 100, tracked_at: Time.utc(2026, 4, 15, 12))
      create_call(total_cost: 4.0, latency_ms: 300, tracked_at: Time.utc(2026, 4, 15, 13))

      stats = described_class.call

      expect(stats.total_cost.to_f).to eq(6.0)
      expect(stats.total_calls.to_i).to eq(2)
      expect(stats.average_cost_per_call.to_f).to eq(3.0)
      expect(stats.average_latency_ms.to_f).to eq(200.0)
    end
  end

  describe LlmCostTracker::Dashboard::MonthlyBudget do
    it "returns nil when no monthly_budget is configured" do
      expect(described_class.status).to be_nil
    end

    it "reports budget, spent, percent, projection, and end label" do
      allow(Time).to receive(:now).and_return(Time.utc(2026, 4, 16, 0, 0, 0))
      LlmCostTracker.configure { |config| config.monthly_budget = 10.0 }
      create_call(total_cost: 2.0, tracked_at: Time.utc(2026, 4, 15, 12))
      create_call(total_cost: 4.0, tracked_at: Time.utc(2026, 4, 15, 13))

      budget = described_class.status

      expect(budget).to include(budget: 10.0, spent: 6.0, percent_used: 60.0)
      expect(budget[:projected_spent]).to be_within(0.01).of(12.0)
      expect(budget[:projected_percent_used]).to be_within(0.01).of(120.0)
      expect(budget[:projected_delta]).to be_within(0.01).of(2.0)
      expect(budget[:projection_end_label]).to eq("Apr 30")
    end

    it "reads monthly budget status from maintained storage totals" do
      now = Time.utc(2026, 4, 16, 0, 0, 0)
      allow(Time).to receive(:now).and_return(now)
      allow(LlmCostTracker::Ledger::Period::Totals).to receive(:call).and_return(month: 7.5)
      LlmCostTracker.configure { |config| config.monthly_budget = 10.0 }

      budget = described_class.status

      expect(LlmCostTracker::Ledger::Period::Totals).to have_received(:call).with(%i[month], time: now)
      expect(budget).to include(spent: 7.5, percent_used: 75.0)
    end

    it "keeps budget percentages at zero for a zero budget" do
      now = Time.utc(2026, 4, 16, 0, 0, 0)
      allow(Time).to receive(:now).and_return(now)
      allow(LlmCostTracker::Ledger::Period::Totals).to receive(:call).and_return(month: 7.5)
      LlmCostTracker.configure { |config| config.monthly_budget = 0.0 }

      budget = described_class.status

      expect(budget).to include(spent: 7.5, percent_used: 0.0, projected_percent_used: 0.0)
      expect(budget[:projected_delta]).to be > 0
    end

    it "builds under-budget projection state when monthly spend is zero" do
      now = Time.utc(2026, 4, 16, 0, 0, 0)
      allow(Time).to receive(:now).and_return(now)
      allow(LlmCostTracker::Ledger::Period::Totals).to receive(:call).and_return(month: 0.0)
      LlmCostTracker.configure { |config| config.monthly_budget = 10.0 }

      budget = described_class.status

      expect(budget).to include(
        projected_spent: 0.0,
        projected_delta_amount: 10.0,
        projected_delta_direction: "under",
        projected_delta_status_class: "lct-budget-projection-status--under",
        fill_modifier: "",
        progress_percent: 0.0,
        projected_marker_percent: 0.0
      )
    end
  end

  describe LlmCostTracker::Dashboard::OverviewStats, "delta comparison" do
    it "returns nil deltas when no previous scope is given" do
      create_call(total_cost: 2.0)

      stats = described_class.call

      expect(stats.cost_delta_percent).to be_nil
      expect(stats.calls_delta_percent).to be_nil
      expect(stats.previous_total_cost).to be_nil
    end

    it "computes delta vs previous period when a previous scope is given" do
      create_call(total_cost: 2.0, tracked_at: Time.utc(2026, 4, 15, 12))
      create_call(total_cost: 6.0, tracked_at: Time.utc(2026, 4, 18, 12))

      current = LlmCostTracker::Call.where(tracked_at: Time.utc(2026, 4, 18)..Time.utc(2026, 4, 18, 23, 59, 59))
      previous = LlmCostTracker::Call.where(tracked_at: Time.utc(2026, 4,
                                                                         15)..Time.utc(2026, 4, 15, 23, 59, 59))

      stats = described_class.call(scope: current, previous_scope: previous)

      expect(stats.total_cost.to_f).to eq(6.0)
      expect(stats.previous_total_cost.to_f).to eq(2.0)
      expect(stats.cost_delta_percent.to_f).to eq(200.0)
      expect(stats.calls_delta_percent.to_f).to eq(0.0)
    end

    it "returns nil delta when previous period has zero cost" do
      create_call(total_cost: 2.0, tracked_at: Time.utc(2026, 4, 18, 12))

      current = LlmCostTracker::Call.where(tracked_at: Time.utc(2026, 4, 18).all_day)
      previous = LlmCostTracker::Call.where(tracked_at: Time.utc(2026, 4, 15).all_day)

      stats = described_class.call(scope: current, previous_scope: previous)

      expect(stats.cost_delta_percent).to be_nil
    end
  end

  describe LlmCostTracker::Dashboard::SpendAnomaly do
    it "returns nil when the current slice is shorter than eight days" do
      create_call(total_cost: 10.0, tracked_at: Time.utc(2026, 4, 20, 12))

      alert = described_class.call(from: Date.new(2026, 4, 18), to: Date.new(2026, 4, 20))

      expect(alert).to be_nil
    end

    it "detects a latest-day spike versus the prior seven-day average" do
      7.times do |offset|
        create_call(
          provider: "openai",
          model: "gpt-4o",
          total_cost: 1.0,
          tracked_at: Time.utc(2026, 4, 13 + offset, 12)
        )
      end
      create_call(
        provider: "openai",
        model: "gpt-4o",
        total_cost: 12.0,
        tracked_at: Time.utc(2026, 4, 20, 12)
      )

      alert = described_class.call(from: Date.new(2026, 4, 13), to: Date.new(2026, 4, 20))

      expect(alert.fetch(:provider)).to eq("openai")
      expect(alert.fetch(:model)).to eq("gpt-4o")
      expect(alert.fetch(:day)).to eq(Date.new(2026, 4, 20))
      expect(alert.fetch(:latest_spend)).to eq(12.0)
      expect(alert.fetch(:baseline_mean)).to eq(1.0)
      expect(alert.fetch(:ratio)).to eq(12.0)
    end

    it "aggregates the anomaly window in SQL" do
      create_call(provider: "openai", model: "gpt-4o", total_cost: 1.0, tracked_at: Time.utc(2026, 4, 19, 12))
      create_call(provider: "openai", model: "gpt-4o", total_cost: 12.0, tracked_at: Time.utc(2026, 4, 20, 12))

      sql = capture_llm_cost_tracker_call_selects do
        described_class.call(from: Date.new(2026, 4, 13), to: Date.new(2026, 4, 20))
      end.join(" ")

      expect(sql).to match(/SUM/i)
      expect(sql).to match(/GROUP BY/i)
    end
  end

  describe LlmCostTracker::Dashboard::ProviderBreakdown do
    it "returns empty array for empty dataset" do
      expect(described_class.call).to eq([])
    end

    it "aggregates cost, calls, and share by provider sorted by spend" do
      create_call(provider: "openai", total_cost: 2.0)
      create_call(provider: "openai", total_cost: 6.0)
      create_call(provider: "anthropic", total_cost: 2.0)

      rows = described_class.call

      expect(rows.map(&:provider)).to eq(%w[openai anthropic])
      expect(rows.first.total_cost).to eq(8.0)
      expect(rows.first.calls).to eq(2)
      expect(rows.first.share_percent).to be_within(0.1).of(80.0)
      expect(rows.last.share_percent).to be_within(0.1).of(20.0)
    end

    it "returns zero share when every row has nil cost" do
      create_call(provider: "openai", total_cost: nil)

      rows = described_class.call

      expect(rows.first.share_percent).to eq(0.0)
      expect(rows.first.calls).to eq(1)
    end
  end

  describe LlmCostTracker::Dashboard::TopModels do
    it "returns top models sorted by total cost" do
      create_call(provider: "openai", model: "gpt-4o", total_cost: 2.0, input_tokens: 10, output_tokens: 5)
      create_call(provider: "openai", model: "gpt-4o", total_cost: 3.0, input_tokens: 20, output_tokens: 10)
      create_call(provider: "anthropic", model: "claude-haiku-4-5", total_cost: 1.0)

      rows = described_class.call(limit: 2)

      expect(rows.map(&:model)).to eq(["gpt-4o", "claude-haiku-4-5"])
      expect(rows.first.total_cost).to eq(5.0)
      expect(rows.first.calls).to eq(2)
      expect(rows.first.total_tokens).to eq(45)
      expect(rows.first.input_tokens).to eq(30)
      expect(rows.first.output_tokens).to eq(15)
      expect(rows.first.average_cost_per_call).to eq(2.5)
    end

    it "sorts by call volume with sort: calls" do
      create_call(model: "cheap", total_cost: 0.1)
      create_call(model: "cheap", total_cost: 0.1)
      create_call(model: "expensive", total_cost: 5.0)

      rows = described_class.call(sort: "calls")

      expect(rows.first.model).to eq("cheap")
      expect(rows.first.calls).to eq(2)
    end

    it "sorts by avg cost per call with sort: avg_cost" do
      create_call(model: "cheap", total_cost: 1.0)
      create_call(model: "cheap", total_cost: 1.0)
      create_call(model: "pricey", total_cost: 5.0)

      rows = described_class.call(sort: "avg_cost")

      expect(rows.first.model).to eq("pricey")
    end

    it "sorts by average latency with nils last" do
      create_call(model: "fast", total_cost: 1.0, latency_ms: 100)
      create_call(model: "slow", total_cost: 1.0, latency_ms: 300)
      create_call(model: "unknown", total_cost: 1.0, latency_ms: nil)

      rows = described_class.call(sort: "latency")

      expect(rows.map(&:model)).to eq(%w[slow fast unknown])
    end
  end

  describe LlmCostTracker::Dashboard::DataQuality do
    it "returns zeros for empty dataset" do
      stats = described_class.call

      expect(stats.total_calls.to_i).to eq(0)
      expect(stats.unknown_pricing_count.to_i).to eq(0)
      expect(stats.untagged_calls_count.to_i).to eq(0)
      expect(described_class.unknown_pricing_by_model(LlmCostTracker::Call.all, total_calls: 0)).to be_empty
    end

    it "counts unknown pricing and untagged calls correctly" do
      create_call(total_cost: 1.0, tags: { env: "prod" })
      create_call(total_cost: nil, tags: {})
      create_call(total_cost: nil, tags: { env: "prod" })

      stats = described_class.call

      expect(stats.total_calls.to_i).to eq(3)
      expect(stats.unknown_pricing_count.to_i).to eq(2)
      expect(stats.untagged_calls_count.to_i).to eq(1)
    end

    it "reports missing latency count" do
      create_call(latency_ms: 100)
      create_call(latency_ms: nil)

      stats = described_class.call

      expect(stats.missing_latency_count.to_i).to eq(1)
    end

    it "groups unknown pricing by model" do
      create_call(model: "unknown-x", total_cost: nil)
      create_call(model: "unknown-x", total_cost: nil)
      create_call(model: "unknown-y", total_cost: nil)

      rows = described_class.unknown_pricing_by_model(LlmCostTracker::Call.all, total_calls: 3)
      counts = rows.index_by(&:model)

      expect(counts.fetch("unknown-x").calls.to_i).to eq(2)
      expect(counts.fetch("unknown-y").calls.to_i).to eq(1)
    end

    it "keeps unknown pricing shares at zero when the total is zero" do
      create_call(model: "unknown-x", total_cost: nil)

      rows = described_class.unknown_pricing_by_model(LlmCostTracker::Call.all, total_calls: 0)

      expect(rows.first.share_percent).to eq(0.0)
    end

    it "keeps the same model name as separate rows when providers differ" do
      create_call(provider: "openrouter", model: "foo", total_cost: nil)
      create_call(provider: "openrouter", model: "foo", total_cost: nil)
      create_call(provider: "custom", model: "foo", total_cost: nil)

      rows = described_class.unknown_pricing_by_model(LlmCostTracker::Call.all, total_calls: 3)
      by_pair = rows.to_h { |row| [[row.provider, row.model], row.calls.to_i] }

      expect(by_pair).to eq(["openrouter", "foo"] => 2, ["custom", "foo"] => 1)
    end

    it "treats cost_status partial or unknown as unknown pricing rows even when total_cost is non-nil" do
      create_call(provider: "openai", model: "gpt-4o", total_cost: 0.42,
                  cost_status: LlmCostTracker::Billing::CostStatus::PARTIAL)
      create_call(provider: "openai", model: "gpt-4o", total_cost: 0.10,
                  cost_status: LlmCostTracker::Billing::CostStatus::COMPLETE)

      rows = described_class.unknown_pricing_by_model(LlmCostTracker::Call.all, total_calls: 2)

      expect(rows.size).to eq(1)
      expect(rows.first).to have_attributes(provider: "openai", model: "gpt-4o", calls: 1)
    end

    it "sums header token columns and pulls per-component cost from line items" do
      call_one = create_call(
        input_tokens: 100,
        cache_read_input_tokens: 50,
        cache_write_input_tokens: 25,
        cache_write_extended_input_tokens: 5,
        audio_input_tokens: 12,
        output_tokens: 40,
        audio_output_tokens: 8,
        hidden_output_tokens: 10
      )
      call_two = create_call(
        input_tokens: 200,
        cache_read_input_tokens: 10,
        cache_write_extended_input_tokens: 2,
        audio_input_tokens: 3,
        output_tokens: 60,
        audio_output_tokens: 2,
        hidden_output_tokens: 5
      )
      build_call_line_item(call_one, kind: "text_token", direction: "input", cache_state: "none", cost: 0.10)
      build_call_line_item(call_one, kind: "audio_token", direction: "input", cache_state: "none", cost: 0.12)
      build_call_line_item(call_two, kind: "text_token", direction: "input", cache_state: "none", cost: 0.30)
      build_call_line_item(call_two, kind: "audio_token", direction: "input", cache_state: "none", cost: 0.03)

      stats = described_class.call

      expect(stats.input_tokens.to_i).to eq(300)
      expect(stats.cache_read_input_tokens.to_i).to eq(60)
      expect(stats.cache_write_input_tokens.to_i).to eq(25)
      expect(stats.cache_write_extended_input_tokens.to_i).to eq(7)
      expect(stats.audio_input_tokens.to_i).to eq(15)
      expect(stats.output_tokens.to_i).to eq(100)
      expect(stats.audio_output_tokens.to_i).to eq(10)
      expect(stats.hidden_output_tokens.to_i).to eq(15)
      expect(stats.billable_tokens.to_i).to eq(517)
      expect(stats.hidden_output_share.to_f).to eq(15.0)

      component_costs = described_class.component_costs(LlmCostTracker::Call.all)
      rows = described_class.usage_rows(stats, component_costs: component_costs)
      regular_input = rows.find { |row| row.fetch(:token_key) == :input_tokens }
      audio_input = rows.find { |row| row.fetch(:token_key) == :audio_input_tokens }
      hidden_output = rows.find { |row| row.fetch(:token_key) == :hidden_output_tokens }

      expect(regular_input.fetch(:cost_value).to_f).to eq(0.4)
      expect(regular_input.fetch(:share_percent)).to be_within(0.1).of(58.03)
      expect(audio_input.fetch(:cost_value).to_f).to eq(0.15)
      expect(hidden_output).to include(token_value: 15, cost_value: nil, share_basis: :output)
      expect(hidden_output.fetch(:share_percent)).to eq(15.0)
      expect(described_class.hidden_output_summary(stats)).to eq(
        hidden_output_tokens: 15,
        output_tokens: 100,
        share_percent: 15.0
      )
    end

    def build_call_line_item(call, kind:, direction:, cache_state:, cost:)
      LlmCostTracker::CallLineItem.create!(
        llm_cost_tracker_call_id: call.id,
        position: call.line_items.count,
        kind: kind,
        direction: direction,
        modality: "audio".eql?(kind.split("_").first) ? "audio" : "text",
        cache_state: cache_state,
        quantity: 1,
        unit: "token",
        cost: cost,
        currency: "USD",
        cost_status: LlmCostTracker::Billing::CostStatus::COMPLETE,
        details: {},
        created_at: Time.now.utc
      )
    end

    it "reads aggregate counters and sums without count fan-out" do
      create_call(total_cost: 1.0, tags: { env: "prod" }, latency_ms: 100)
      create_call(total_cost: nil, tags: {})

      statements = capture_llm_cost_tracker_call_selects { described_class.call }

      expect(statements.size).to eq(1)
    end

    it "counts streaming calls and streams missing usage" do
      create_call(stream: true,  usage_source: "stream_final", provider_response_id: "resp_1")
      create_call(stream: true,  usage_source: "unknown")
      create_call(stream: false, usage_source: "response", provider_response_id: "resp_2")

      stats = described_class.call

      expect(stats.streaming_count.to_i).to eq(2)
      expect(stats.streaming_missing_usage_count.to_i).to eq(1)
      expect(stats.missing_provider_response_id_count.to_i).to eq(1)
    end

    it "breaks streaming health down per provider, sorted by stream volume" do
      create_call(provider: "openai",     stream: true,  usage_source: "stream_final")
      create_call(provider: "openai",     stream: true,  usage_source: "stream_final")
      create_call(provider: "openrouter", stream: true,  usage_source: "unknown")
      create_call(provider: "openrouter", stream: true,  usage_source: "stream_final")
      create_call(provider: "anthropic",  stream: false, usage_source: "response")

      rows = described_class.streaming_health_rows(LlmCostTracker::Call.all, total_streaming: 4)

      expect(rows.map(&:provider)).to eq(%w[openai openrouter])
      openai = rows.find { |row| row.provider == "openai" }
      openrouter = rows.find { |row| row.provider == "openrouter" }
      expect(openai.streams).to eq(2)
      expect(openai.with_usage).to eq(2)
      expect(openai.unknown).to eq(0)
      expect(openai.unknown_share).to eq(0.0)
      expect(openrouter.streams).to eq(2)
      expect(openrouter.with_usage).to eq(1)
      expect(openrouter.unknown).to eq(1)
      expect(openrouter.unknown_share).to eq(50.0)
    end

    it "returns no streaming health rows when the slice has no streams" do
      rows = described_class.streaming_health_rows(LlmCostTracker::Call.all, total_streaming: 0)

      expect(rows).to eq([])
    end

    it "groups service charges by provider, component, and status" do
      openai_call = create_call(provider: "openai")
      anthropic_call = create_call(provider: "anthropic")
      build_service_line_item(
        call: openai_call,
        position: 0,
        kind: "web_search_request",
        unit: "request",
        quantity: 2,
        rate_quantity: 1000,
        cost: 0.02,
        cost_status: LlmCostTracker::Billing::CostStatus::COMPLETE
      )
      build_service_line_item(
        call: openai_call,
        position: 1,
        kind: "web_search_request",
        unit: "request",
        quantity: 1,
        rate_quantity: 1,
        cost: nil,
        cost_status: LlmCostTracker::Billing::CostStatus::UNKNOWN
      )
      build_service_line_item(
        call: anthropic_call,
        position: 0,
        kind: "code_execution_hour",
        unit: "hour",
        quantity: 1,
        rate_quantity: 1,
        cost: 0.05,
        cost_status: LlmCostTracker::Billing::CostStatus::COMPLETE
      )

      rows = described_class.service_charge_rows(LlmCostTracker::Call.where(provider: "openai"))
      row_by_status = rows.index_by(&:cost_status)

      expect(row_by_status.fetch("complete").provider).to eq("openai")
      expect(row_by_status.fetch("complete").component).to eq("web_search_request")
      expect(row_by_status.fetch("complete").quantity).to eq(2)
      expect(row_by_status.fetch("unknown").quantity).to eq(1)
    end

    def build_service_line_item(call:, position:, kind:, unit:, quantity:, rate_quantity:, cost:, cost_status:)
      LlmCostTracker::CallLineItem.create!(
        llm_cost_tracker_call_id: call.id,
        position: position,
        kind: kind,
        direction: "neither",
        modality: "text",
        cache_state: "none",
        quantity: quantity,
        unit: unit,
        rate_quantity: rate_quantity,
        cost: cost,
        currency: "USD",
        cost_status: cost_status,
        details: {},
        created_at: Time.now.utc
      )
    end
  end

  describe LlmCostTracker::Dashboard::TagBreakdown do
    it "returns top values without limiting summary counters" do
      create_call(total_cost: 5.0, tags: { feature: "chat" })
      create_call(total_cost: 2.0, tags: { feature: "batch" })
      create_call(total_cost: 1.0, tags: { feature: "search" })
      create_call(total_cost: 9.0, tags: { other: "missing" })

      breakdown = described_class.call(key: "feature", limit: 2)

      expect(breakdown.rows.map(&:value)).to eq(%w[chat batch])
      expect(breakdown.total_calls).to eq(4)
      expect(breakdown.tagged_calls).to eq(3)
      expect(breakdown.distinct_values).to eq(3)
      expect(breakdown.distinct_values > breakdown.rows.size).to be true
    end

    it "returns empty rows when no calls carry the tag key" do
      create_call(tags: { other: "missing" })

      breakdown = described_class.call(key: "feature")

      expect(breakdown.rows).to eq([])
      expect(breakdown.total_calls).to eq(1)
      expect(breakdown.tagged_calls).to eq(0)
      expect(breakdown.distinct_values).to eq(0)
    end
  end

  describe LlmCostTracker::Dashboard::TagKeyExplorer do
    it "returns empty array when no tagged calls exist" do
      create_call(tags: {})

      rows = described_class.call

      expect(rows).to eq([])
    end

    it "discovers tag keys and their call counts" do
      create_call(tags: { env: "prod", service: "api" })
      create_call(tags: { env: "staging" })
      create_call(tags: { service: "worker" })

      rows = described_class.call
      keys = rows.map(&:key)

      expect(keys).to include("env", "service")
    end

    it "counts distinct values per key" do
      create_call(tags: { env: "prod" })
      create_call(tags: { env: "staging" })
      create_call(tags: { env: "prod" })

      rows = described_class.call
      env_row = rows.find { |row| row.key == "env" }

      expect(env_row.calls_count).to eq(3)
      expect(env_row.distinct_values).to eq(2)
    end

    it "orders by call count descending" do
      create_call(tags: { rare: "x" })
      create_call(tags: { common: "a" })
      create_call(tags: { common: "b" })

      rows = described_class.call

      expect(rows.first.key).to eq("common")
    end

    it "limits discovered tag keys" do
      create_call(tags: { first: "x" })
      create_call(tags: { second: "x" })

      rows = described_class.call(limit: 1)

      expect(rows.size).to eq(1)
    end

    it "joins llm_cost_tracker_call_tags to discover keys" do
      create_call(tags: { env: "prod", service: "api" })

      captured_sql = nil
      allow(LlmCostTracker::Call).to receive(:find_by_sql) do |sql|
        captured_sql = sql
        []
      end

      described_class.call

      expect(captured_sql).to include("llm_cost_tracker_call_tags")
      expect(captured_sql).to include("LIMIT 100")
    end
  end
end
