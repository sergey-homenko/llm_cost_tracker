# frozen_string_literal: true

require "spec_helper"
require "active_record"
require "active_support/notifications"
require "llm_cost_tracker/llm_api_call"

ENV["RAILS_ENV"] ||= "test"

require_relative "../../dummy/config/environment"

RSpec.describe "LlmCostTracker dashboard services" do
  def reset_database!(latency: true, streaming: false, usage_breakdown: true)
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")

    ActiveRecord::Schema.verbose = false
    table_definition = llm_api_calls_table_definition(latency:, streaming:, usage_breakdown:)
    ActiveRecord::Schema.define do
      create_table :llm_api_calls, &table_definition
    end

    LlmCostTracker::LlmApiCall.reset_column_information
  end

  def create_call(**overrides)
    attrs = call_defaults.merge(overrides)
    attrs[:total_tokens] = total_tokens_for(attrs)
    attrs[:tags] = attrs.fetch(:tags).to_json
    normalize_call_columns!(attrs)

    LlmCostTracker::LlmApiCall.create!(attrs)
  end

  def llm_api_calls_table_definition(latency:, streaming:, usage_breakdown:)
    proc do |t|
      add_usage_columns(t, usage_breakdown:)
      add_cost_columns(t, usage_breakdown:)
      add_tracking_columns(t, latency:, streaming:, usage_breakdown:)
      t.timestamps
    end
  end

  def add_usage_columns(table, usage_breakdown:)
    table.string :provider, null: false
    table.string :model, null: false
    table.integer :input_tokens, null: false, default: 0
    table.integer :output_tokens, null: false, default: 0
    table.integer :total_tokens, null: false, default: 0
    return unless usage_breakdown

    table.integer :cache_read_input_tokens, null: false, default: 0
    table.integer :cache_write_input_tokens, null: false, default: 0
    table.integer :hidden_output_tokens, null: false, default: 0
  end

  def add_cost_columns(table, usage_breakdown:)
    table.decimal :input_cost, precision: 20, scale: 8
    table.decimal :cache_read_input_cost, precision: 20, scale: 8 if usage_breakdown
    table.decimal :cache_write_input_cost, precision: 20, scale: 8 if usage_breakdown
    table.decimal :output_cost, precision: 20, scale: 8
    table.decimal :total_cost, precision: 20, scale: 8
  end

  def add_tracking_columns(table, latency:, streaming:, usage_breakdown:)
    table.integer :latency_ms if latency
    if streaming
      table.boolean :stream, null: false, default: false
      table.string  :usage_source
    end
    table.string :provider_response_id
    table.string :pricing_mode if usage_breakdown
    table.text :tags
    table.datetime :tracked_at, null: false
  end

  def call_defaults
    {
      provider: "openai",
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      cache_read_input_tokens: 0,
      cache_write_input_tokens: 0,
      hidden_output_tokens: 0,
      input_cost: 0.1,
      output_cost: 0.2,
      cache_read_input_cost: 0.0,
      cache_write_input_cost: 0.0,
      total_cost: 1.0,
      latency_ms: 100,
      stream: false,
      usage_source: nil,
      provider_response_id: nil,
      tags: {},
      tracked_at: Time.utc(2026, 4, 18, 12)
    }
  end

  def total_tokens_for(attrs)
    attrs.fetch(:input_tokens) +
      attrs.fetch(:cache_read_input_tokens) +
      attrs.fetch(:cache_write_input_tokens) +
      attrs.fetch(:output_tokens)
  end

  def normalize_call_columns!(attrs)
    attrs.delete(:latency_ms) unless LlmCostTracker::LlmApiCall.latency_column?
    attrs.delete(:stream) unless LlmCostTracker::LlmApiCall.stream_column?
    attrs.delete(:usage_source) unless LlmCostTracker::LlmApiCall.usage_source_column?
    attrs.delete(:provider_response_id) unless LlmCostTracker::LlmApiCall.provider_response_id_column?
    unless LlmCostTracker::LlmApiCall.usage_breakdown_columns?
      attrs.delete(:cache_read_input_tokens)
      attrs.delete(:cache_write_input_tokens)
      attrs.delete(:hidden_output_tokens)
    end
    unless LlmCostTracker::LlmApiCall.usage_breakdown_cost_columns?
      attrs.delete(:cache_read_input_cost)
      attrs.delete(:cache_write_input_cost)
    end
    attrs.delete(:pricing_mode) unless LlmCostTracker::LlmApiCall.pricing_mode_column?
  end

  def capture_llm_api_call_selects
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s
      next if payload[:name] == "SCHEMA"
      next unless sql.match?(/\ASELECT/i)
      next unless sql.include?("llm_api_calls")

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
    ActiveRecord::Base.connection.disconnect!
  end

  describe LlmCostTracker::Pagination do
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
      expect(page.limit).to eq(200)
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

    context "with stream and usage_source columns" do
      before do
        ActiveRecord::Base.connection.disconnect!
        reset_database!(streaming: true)
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

      expect(stats.total_cost).to eq(0.0)
      expect(stats.total_calls).to eq(0)
      expect(stats.average_cost_per_call).to eq(0.0)
      expect(stats.average_latency_ms).to be_nil
      expect(stats.monthly_budget_status).to be_nil
    end

    it "aggregates total cost, calls, average cost, latency, and budget status" do
      allow(Time).to receive(:now).and_return(Time.utc(2026, 4, 16, 0, 0, 0))
      LlmCostTracker.configure { |config| config.monthly_budget = 10.0 }
      create_call(total_cost: 2.0, latency_ms: 100)
      create_call(total_cost: 4.0, latency_ms: 300)

      stats = described_class.call

      expect(stats.total_cost).to eq(6.0)
      expect(stats.total_calls).to eq(2)
      expect(stats.average_cost_per_call).to eq(3.0)
      expect(stats.average_latency_ms).to eq(200.0)
      expect(stats.monthly_budget_status).to include(budget: 10.0, spent: 6.0, percent_used: 60.0)
      expect(stats.monthly_budget_status[:projected_spent]).to be_within(0.01).of(12.0)
      expect(stats.monthly_budget_status[:projected_percent_used]).to be_within(0.01).of(120.0)
      expect(stats.monthly_budget_status[:projected_delta]).to be_within(0.01).of(2.0)
      expect(stats.monthly_budget_status[:projection_end_label]).to eq("Apr 30")
    end

    it "omits average latency when the column is unavailable" do
      ActiveRecord::Base.connection.disconnect!
      reset_database!(latency: false)
      create_call(total_cost: 2.0)

      expect(described_class.call.average_latency_ms).to be_nil
    end

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

      current = LlmCostTracker::LlmApiCall.where(tracked_at: Time.utc(2026, 4, 18)..Time.utc(2026, 4, 18, 23, 59, 59))
      previous = LlmCostTracker::LlmApiCall.where(tracked_at: Time.utc(2026, 4, 15)..Time.utc(2026, 4, 15, 23, 59, 59))

      stats = described_class.call(scope: current, previous_scope: previous)

      expect(stats.total_cost).to eq(6.0)
      expect(stats.previous_total_cost).to eq(2.0)
      expect(stats.cost_delta_percent).to eq(200.0)
      expect(stats.calls_delta_percent).to eq(0.0)
    end

    it "returns nil delta when previous period has zero cost" do
      create_call(total_cost: 2.0, tracked_at: Time.utc(2026, 4, 18, 12))

      current = LlmCostTracker::LlmApiCall.where(tracked_at: Time.utc(2026, 4, 18).all_day)
      previous = LlmCostTracker::LlmApiCall.where(tracked_at: Time.utc(2026, 4, 15).all_day)

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

      expect(alert.provider).to eq("openai")
      expect(alert.model).to eq("gpt-4o")
      expect(alert.day).to eq(Date.new(2026, 4, 20))
      expect(alert.latest_spend).to eq(12.0)
      expect(alert.baseline_mean).to eq(1.0)
      expect(alert.ratio).to eq(12.0)
    end

    it "aggregates the anomaly window in SQL" do
      create_call(provider: "openai", model: "gpt-4o", total_cost: 1.0, tracked_at: Time.utc(2026, 4, 19, 12))
      create_call(provider: "openai", model: "gpt-4o", total_cost: 12.0, tracked_at: Time.utc(2026, 4, 20, 12))

      sql = capture_llm_api_call_selects do
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

    it "falls back to cost sort when sort: latency but column absent" do
      ActiveRecord::Base.connection.disconnect!
      reset_database!(latency: false)
      create_call(model: "a", total_cost: 1.0)
      create_call(model: "b", total_cost: 5.0)

      rows = described_class.call(sort: "latency")

      expect(rows.first.model).to eq("b")
    end
  end

  describe LlmCostTracker::Dashboard::DataQuality do
    it "returns zeros for empty dataset" do
      stats = described_class.call

      expect(stats.total_calls).to eq(0)
      expect(stats.unknown_pricing_count).to eq(0)
      expect(stats.untagged_calls_count).to eq(0)
      expect(stats.unknown_pricing_by_model).to be_empty
    end

    it "counts unknown pricing and untagged calls correctly" do
      create_call(total_cost: 1.0, tags: { env: "prod" })
      create_call(total_cost: nil, tags: {})
      create_call(total_cost: nil, tags: { env: "prod" })

      stats = described_class.call

      expect(stats.total_calls).to eq(3)
      expect(stats.unknown_pricing_count).to eq(2)
      expect(stats.untagged_calls_count).to eq(1)
    end

    it "reports missing latency count when column is present" do
      create_call(latency_ms: 100)
      create_call(latency_ms: nil)

      stats = described_class.call

      expect(stats.latency_column_present).to be true
      expect(stats.missing_latency_count).to eq(1)
    end

    it "groups unknown pricing by model" do
      create_call(model: "unknown-x", total_cost: nil)
      create_call(model: "unknown-x", total_cost: nil)
      create_call(model: "unknown-y", total_cost: nil)

      stats = described_class.call

      expect(stats.unknown_pricing_by_model["unknown-x"]).to eq(2)
      expect(stats.unknown_pricing_by_model["unknown-y"]).to eq(1)
    end

    it "sums usage and cost breakdown columns when present" do
      create_call(
        input_tokens: 100,
        cache_read_input_tokens: 50,
        cache_write_input_tokens: 25,
        output_tokens: 40,
        hidden_output_tokens: 10,
        input_cost: 0.10,
        cache_read_input_cost: 0.02,
        cache_write_input_cost: 0.03,
        output_cost: 0.20
      )
      create_call(
        input_tokens: 200,
        cache_read_input_tokens: 10,
        output_tokens: 60,
        hidden_output_tokens: 5,
        input_cost: 0.30,
        cache_read_input_cost: 0.01,
        output_cost: 0.40
      )

      stats = described_class.call

      expect(stats.usage_breakdown_column_present).to be true
      expect(stats.input_tokens).to eq(300)
      expect(stats.cache_read_input_tokens).to eq(60)
      expect(stats.cache_write_input_tokens).to eq(25)
      expect(stats.output_tokens).to eq(100)
      expect(stats.hidden_output_tokens).to eq(15)
      expect(stats.input_cost).to eq(0.4)
      expect(stats.cache_read_input_cost).to eq(0.03)
      expect(stats.cache_write_input_cost).to eq(0.03)
      expect(stats.output_cost).to eq(0.6)
    end

    it "reads aggregate counters and sums without count fan-out" do
      create_call(total_cost: 1.0, tags: { env: "prod" }, latency_ms: 100)
      create_call(total_cost: nil, tags: {})

      LlmCostTracker::LlmApiCall.latency_column?
      LlmCostTracker::LlmApiCall.stream_column?
      LlmCostTracker::LlmApiCall.provider_response_id_column?
      LlmCostTracker::LlmApiCall.usage_breakdown_columns?
      LlmCostTracker::LlmApiCall.usage_breakdown_cost_columns?

      statements = capture_llm_api_call_selects { described_class.call }

      expect(statements.size).to eq(2)
    end

    it "reports usage breakdown absence when the schema lacks canonical breakdown columns" do
      ActiveRecord::Base.connection.disconnect!
      reset_database!(usage_breakdown: false)
      create_call(input_tokens: 100, output_tokens: 50)

      stats = described_class.call

      expect(stats.usage_breakdown_column_present).to be false
      expect(stats.input_tokens).to eq(100)
      expect(stats.cache_read_input_tokens).to be_nil
      expect(stats.hidden_output_tokens).to be_nil
    end

    it "reports stream column absence when the schema lacks it" do
      stats = described_class.call

      expect(stats.stream_column_present).to be false
      expect(stats.streaming_count).to be_nil
      expect(stats.streaming_missing_usage_count).to be_nil
      expect(stats.provider_response_id_column_present).to be true
      expect(stats.missing_provider_response_id_count).to eq(0)
    end

    context "with stream and usage_source columns" do
      before do
        ActiveRecord::Base.connection.disconnect!
        reset_database!(streaming: true)
      end

      it "counts streaming calls and streams missing usage" do
        create_call(stream: true,  usage_source: "stream_final", provider_response_id: "resp_1")
        create_call(stream: true,  usage_source: "unknown")
        create_call(stream: false, usage_source: "response", provider_response_id: "resp_2")

        stats = described_class.call

        expect(stats.stream_column_present).to be true
        expect(stats.streaming_count).to eq(2)
        expect(stats.streaming_missing_usage_count).to eq(1)
        expect(stats.provider_response_id_column_present).to be true
        expect(stats.missing_provider_response_id_count).to eq(1)
      end
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
      env_row = rows.find { |r| r.key == "env" }

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

    it "uses JSON_TABLE-based discovery on MySQL" do
      create_call(tags: { env: "prod", service: "api" })
      create_call(tags: { env: "staging" })

      connection = LlmCostTracker::LlmApiCall.connection
      captured_sql = nil

      allow(connection).to receive(:adapter_name).and_return("Mysql2")
      allow(connection).to receive(:select_all) do |sql|
        captured_sql = sql
        ActiveRecord::Result.new(
          %w[key calls_count distinct_values],
          [["env", 2, 2], ["service", 1, 1]]
        )
      end

      rows = described_class.call

      expect(captured_sql).to include("JSON_TABLE")
      expect(captured_sql).to include("JSON_KEYS")
      expect(captured_sql).to include("LIMIT 100")
      expect(rows.map(&:key)).to eq(%w[env service])
      expect(rows.first.calls_count).to eq(2)
      expect(rows.first.distinct_values).to eq(2)
    end
  end
end
