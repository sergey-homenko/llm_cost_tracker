# frozen_string_literal: true

require "active_record"
require "json"
require "spec_helper"

require "llm_cost_tracker/llm_api_call"
require_relative "../../../app/services/llm_cost_tracker/dashboard/errors"
require_relative "../../../app/services/llm_cost_tracker/dashboard/page"
require_relative "../../../app/services/llm_cost_tracker/dashboard/filter"
require_relative "../../../app/services/llm_cost_tracker/dashboard/time_series"
require_relative "../../../app/services/llm_cost_tracker/dashboard/overview_stats"
require_relative "../../../app/services/llm_cost_tracker/dashboard/top_models"
require_relative "../../../app/services/llm_cost_tracker/dashboard/top_tags"

RSpec.describe "LlmCostTracker dashboard services" do
  def reset_database!(latency: true)
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
        t.integer :latency_ms if latency
        t.text :tags
        t.datetime :tracked_at, null: false

        t.timestamps
      end
    end

    LlmCostTracker::LlmApiCall.reset_column_information
  end

  def create_call(**overrides)
    defaults = {
      provider: "openai",
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      total_cost: 1.0,
      latency_ms: 100,
      tags: {},
      tracked_at: Time.utc(2026, 4, 18, 12)
    }
    attrs = defaults.merge(overrides)
    attrs[:total_tokens] = attrs.fetch(:input_tokens) + attrs.fetch(:output_tokens)
    attrs[:tags] = attrs.fetch(:tags).to_json
    attrs.delete(:latency_ms) unless LlmCostTracker::LlmApiCall.latency_column?

    LlmCostTracker::LlmApiCall.create!(attrs)
  end

  before do
    reset_database!
  end

  after do
    ActiveRecord::Base.connection.disconnect!
  end

  describe LlmCostTracker::Dashboard::Page do
    it "uses defaults for nil params" do
      page = described_class.from(nil)

      expect(page.page).to eq(1)
      expect(page.per).to eq(50)
      expect(page.offset).to eq(0)
    end

    it "normalizes invalid pagination params" do
      page = described_class.from("page" => "-1", "per" => "10000")

      expect(page.page).to eq(1)
      expect(page.per).to eq(200)
      expect(page.limit).to eq(200)
      expect(page.offset).to eq(0)
      expect(page.prev_page?).to be false
    end

    it "calculates offsets and next-page state" do
      page = described_class.from(page: "3", per: "50")

      expect(page.offset).to eq(100)
      expect(page.prev_page?).to be true
      expect(page.next_page?(151)).to be true
      expect(page.next_page?(150)).to be false
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

      relation = described_class.apply(
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

      relation = described_class.apply(params: { from: "not-a-date", to: "also-bad" })

      expect(relation.count).to eq(1)
    end

    it "ignores malformed non-hash tag params" do
      create_call(tags: { feature: "chat" })

      relation = described_class.apply(params: { tag: "malformed" })

      expect(relation.count).to eq(1)
    end

    it "raises an invalid filter error for unsafe tag keys" do
      expect do
        described_class.apply(params: { tag: { ";DROP TABLE" => "x" } })
      end.to raise_error(LlmCostTracker::Dashboard::InvalidFilter, /invalid tag key/)
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
      stats = described_class.build

      expect(stats.total_cost).to eq(0.0)
      expect(stats.total_calls).to eq(0)
      expect(stats.average_cost_per_call).to eq(0.0)
      expect(stats.average_latency_ms).to be_nil
      expect(stats.monthly_budget_status).to be_nil
    end

    it "aggregates total cost, calls, average cost, latency, and budget status" do
      LlmCostTracker.configure { |config| config.monthly_budget = 10.0 }
      create_call(total_cost: 2.0, latency_ms: 100)
      create_call(total_cost: 4.0, latency_ms: 300)

      stats = described_class.build

      expect(stats.total_cost).to eq(6.0)
      expect(stats.total_calls).to eq(2)
      expect(stats.average_cost_per_call).to eq(3.0)
      expect(stats.average_latency_ms).to eq(200.0)
      expect(stats.monthly_budget_status).to include(budget: 10.0, spent: 6.0, percent_used: 60.0)
    end

    it "omits average latency when the column is unavailable" do
      ActiveRecord::Base.connection.disconnect!
      reset_database!(latency: false)
      create_call(total_cost: 2.0)

      expect(described_class.build.average_latency_ms).to be_nil
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
  end

  describe LlmCostTracker::Dashboard::TopTags do
    it "returns feature tag breakdowns by default" do
      create_call(total_cost: 2.0, tags: { feature: "chat" })
      create_call(total_cost: 1.0, tags: { feature: "summarizer" })

      expect(described_class.call).to eq(
        "feature" => [["chat", 2.0], ["summarizer", 1.0]]
      )
    end

    it "omits empty tag breakdowns" do
      expect(described_class.call).to eq({})
    end
  end
end
