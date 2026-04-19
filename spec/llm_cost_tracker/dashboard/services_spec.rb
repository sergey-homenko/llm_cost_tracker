# frozen_string_literal: true

require "spec_helper"

ENV["RAILS_ENV"] ||= "test"

require_relative "../../dummy/config/environment"

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

    it "calculates offsets and next-page state" do
      page = described_class.call(page: "3", per: "50")

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

    it "ignores malformed non-hash tag params" do
      create_call(tags: { feature: "chat" })

      relation = described_class.call(params: { tag: "malformed" })

      expect(relation.count).to eq(1)
    end

    it "merges tag_key and tag_value into the tag filter" do
      create_call(model: "chat-model", tags: { feature: "chat" })
      create_call(model: "summary-model", tags: { feature: "summarizer" })

      relation = described_class.call(params: { tag_key: "feature", tag_value: "summarizer" })

      expect(relation.pluck(:model)).to eq(["summary-model"])
    end

    it "raises an invalid filter error for unsafe tag keys" do
      expect do
        described_class.call(params: { tag: { ";DROP TABLE" => "x" } })
      end.to raise_error(LlmCostTracker::InvalidFilterError, /invalid tag key/)
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
      LlmCostTracker.configure { |config| config.monthly_budget = 10.0 }
      create_call(total_cost: 2.0, latency_ms: 100)
      create_call(total_cost: 4.0, latency_ms: 300)

      stats = described_class.call

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

      expect(described_class.call.average_latency_ms).to be_nil
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
end
