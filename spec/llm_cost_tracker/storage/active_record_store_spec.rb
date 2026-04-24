# frozen_string_literal: true

require "spec_helper"
require "active_record"
require "json"
require "tempfile"

RSpec.describe "ActiveRecord storage integration" do
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
        t.integer :cache_read_input_tokens, null: false, default: 0
        t.integer :cache_write_input_tokens, null: false, default: 0
        t.integer :hidden_output_tokens, null: false, default: 0
        t.decimal :input_cost, precision: 20, scale: 8
        t.decimal :cache_read_input_cost, precision: 20, scale: 8
        t.decimal :cache_write_input_cost, precision: 20, scale: 8
        t.decimal :output_cost, precision: 20, scale: 8
        t.decimal :total_cost, precision: 20, scale: 8
        t.integer :latency_ms
        t.boolean :stream, null: false, default: false
        t.string :usage_source
        t.string :provider_response_id
        t.string :pricing_mode
        t.text :tags
        t.datetime :tracked_at, null: false

        t.timestamps
      end

      create_table :llm_cost_tracker_monthly_totals do |t|
        t.date :month_start, null: false
        t.decimal :total_cost, precision: 20, scale: 8, null: false, default: 0

        t.timestamps
      end

      add_index :llm_cost_tracker_monthly_totals, :month_start, unique: true
    end

    LlmCostTracker::LlmApiCall.reset_column_information if defined?(LlmCostTracker::LlmApiCall)
    LlmCostTracker::MonthlyTotal.reset_column_information if defined?(LlmCostTracker::MonthlyTotal)

    LlmCostTracker.configure do |config|
      config.storage_backend = :active_record
    end
  end

  after do
    ActiveRecord::Base.connection.disconnect!
  end

  def llm_api_call_model
    require "llm_cost_tracker/llm_api_call" unless defined?(LlmCostTracker::LlmApiCall)

    LlmCostTracker::LlmApiCall
  end

  def monthly_total_model
    require "llm_cost_tracker/monthly_total" unless defined?(LlmCostTracker::MonthlyTotal)

    LlmCostTracker::MonthlyTotal
  end

  it "lazy-loads the ActiveRecord store and persists events" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 500,
      latency_ms: 250,
      user_id: 42,
      feature: "chat"
    )

    expect(llm_api_call_model.count).to eq(1)

    call = llm_api_call_model.first
    expect(call.provider).to eq("openai")
    expect(call.model).to eq("gpt-4o")
    expect(call.total_cost.to_f).to eq(0.0075)
    expect(call.latency_ms).to eq(250)
    expect(call.parsed_tags).to include("user_id" => "42", "feature" => "chat")
  end

  it "persists canonical usage and cost breakdowns when columns are present" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 900,
      output_tokens: 500,
      cache_read_input_tokens: 100,
      hidden_output_tokens: 20
    )

    call = llm_api_call_model.first
    expect(call.input_tokens).to eq(900)
    expect(call.cache_read_input_tokens).to eq(100)
    expect(call.cache_write_input_tokens).to eq(0)
    expect(call.hidden_output_tokens).to eq(20)
    expect(call.input_cost.to_f).to eq(0.00225)
    expect(call.cache_read_input_cost.to_f).to eq(0.000125)
    expect(call.cache_write_input_cost.to_f).to eq(0.0)
    expect(call.total_cost.to_f).to eq(0.007375)
  end

  it "persists pricing_mode when the column is present" do
    LlmCostTracker.configure do |config|
      config.pricing_overrides = {
        "batchable-model" => {
          input: 1.0,
          output: 2.0,
          batch_input: 0.5,
          batch_output: 1.0
        }
      }
    end

    LlmCostTracker.track(
      provider: :custom,
      model: "batchable-model",
      input_tokens: 1_000_000,
      output_tokens: 1_000_000,
      pricing_mode: :batch
    )

    call = llm_api_call_model.first
    expect(call.pricing_mode).to eq("batch")
    expect(call.total_cost.to_f).to eq(1.5)
  end

  it "keeps persisted historical costs when the price file changes for later requests" do
    Tempfile.create(["llm-prices-old", ".json"]) do |old_file|
      Tempfile.create(["llm-prices-new", ".json"]) do |new_file|
        old_file.write(JSON.generate(
                         "models" => {
                           "snapshot-model" => { "input" => 1.0, "output" => 2.0 }
                         }
                       ))
        old_file.close

        new_file.write(JSON.generate(
                         "models" => {
                           "snapshot-model" => { "input" => 3.0, "output" => 4.0 }
                         }
                       ))
        new_file.close

        LlmCostTracker.configure do |config|
          config.prices_file = old_file.path
        end

        LlmCostTracker.track(
          provider: :openai,
          model: "snapshot-model",
          input_tokens: 1_000_000,
          output_tokens: 1_000_000
        )

        LlmCostTracker.configure do |config|
          config.prices_file = new_file.path
        end

        LlmCostTracker.track(
          provider: :openai,
          model: "snapshot-model",
          input_tokens: 1_000_000,
          output_tokens: 1_000_000
        )

        calls = llm_api_call_model.order(:id).to_a

        expect(calls.size).to eq(2)
        expect(calls.first.input_cost.to_f).to eq(1.0)
        expect(calls.first.output_cost.to_f).to eq(2.0)
        expect(calls.first.total_cost.to_f).to eq(3.0)
        expect(calls.second.input_cost.to_f).to eq(3.0)
        expect(calls.second.output_cost.to_f).to eq(4.0)
        expect(calls.second.total_cost.to_f).to eq(7.0)
        expect(llm_api_call_model.sum(:total_cost).to_f).to eq(10.0)
      end
    end
  end

  it "keeps monthly budget rollups in sync" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o-mini",
      input_tokens: 1_000,
      output_tokens: 0
    )

    month_total = monthly_total_model.find_by!(month_start: Date.current.beginning_of_month)

    expect(monthly_total_model.count).to eq(1)
    expect(month_total.total_cost.to_f).to eq(0.00265)
    expect(LlmCostTracker::Storage::ActiveRecordStore.monthly_total).to eq(0.00265)
  end

  it "falls back to llm_api_calls sums when monthly rollups are unavailable" do
    ActiveRecord::Base.connection.drop_table(:llm_cost_tracker_monthly_totals)

    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )

    expect(LlmCostTracker::Storage::ActiveRecordStore.monthly_total).to eq(0.0025)
  end

  it "does not treat latency as a tag" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      latency_ms: 123
    )

    expect(llm_api_call_model.first.parsed_tags).not_to have_key("latency_ms")
  end

  it "persists provider_response_id without treating it as a tag" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      provider_response_id: "chatcmpl_123"
    )

    call = llm_api_call_model.first

    expect(call.provider_response_id).to eq("chatcmpl_123")
    expect(call.parsed_tags).not_to have_key("provider_response_id")
  end

  it "finds stringified numeric tags through by_tag" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      user_id: 42
    )

    expect(llm_api_call_model.by_tag("user_id", "42").count).to eq(1)
  end

  it "filters by multiple tags through by_tags" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      user_id: 42,
      feature: "chat"
    )
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      user_id: 42,
      feature: "summarizer"
    )

    matching_calls = llm_api_call_model.by_tags(user_id: 42, feature: "chat")

    expect(matching_calls.count).to eq(1)
    expect(matching_calls.first.parsed_tags["feature"]).to eq("chat")
  end

  it "aggregates cost by any tag key" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0,
      feature: "chat"
    )
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o-mini",
      input_tokens: 1_000,
      output_tokens: 0,
      feature: "summarizer"
    )
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o-mini",
      input_tokens: 1_000,
      output_tokens: 0
    )

    expect(llm_api_call_model.this_month.cost_by_tag("feature")).to eq(
      "chat" => 0.0025,
      "summarizer" => 0.00015,
      "(untagged)" => 0.00015
    )
  end

  it "groups by tag keys on the SQL side" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0,
      feature: "chat"
    )
    LlmCostTracker.track(
      provider: :anthropic,
      model: "claude-haiku-4-5",
      input_tokens: 1_000,
      output_tokens: 0,
      feature: "summarizer"
    )

    expect(llm_api_call_model.group_by_tag("feature").to_sql).to include("json_extract")
    expect(llm_api_call_model.group_by_tag("feature").sum(:total_cost).transform_values(&:to_f)).to eq(
      "chat" => 0.0025,
      "summarizer" => 0.001
    )
  end

  it "groups costs by day on the SQL side" do
    llm_api_call_model.create!(
      provider: "openai",
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15,
      total_cost: 1.25,
      tags: "{}",
      tracked_at: Time.utc(2026, 4, 18, 10, 30)
    )
    llm_api_call_model.create!(
      provider: "openai",
      model: "gpt-4o-mini",
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15,
      total_cost: 2.75,
      tags: "{}",
      tracked_at: Time.utc(2026, 4, 18, 23, 59)
    )
    llm_api_call_model.create!(
      provider: "anthropic",
      model: "claude-haiku-4-5",
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15,
      total_cost: 3.5,
      tags: "{}",
      tracked_at: Time.utc(2026, 4, 19, 0, 1)
    )

    expect(llm_api_call_model.group_by_period(:day).to_sql).to include("strftime")
    expect(llm_api_call_model.group_by_period(:day).sum(:total_cost).transform_values(&:to_f)).to eq(
      "2026-04-18" => 4.0,
      "2026-04-19" => 3.5
    )
  end

  it "groups costs by month on the SQL side" do
    llm_api_call_model.create!(
      provider: "openai",
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15,
      total_cost: 1.25,
      tags: "{}",
      tracked_at: Time.utc(2026, 4, 18)
    )
    llm_api_call_model.create!(
      provider: "anthropic",
      model: "claude-haiku-4-5",
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15,
      total_cost: 3.5,
      tags: "{}",
      tracked_at: Time.utc(2026, 5, 1)
    )

    expect(llm_api_call_model.group_by_period(:month).sum(:total_cost).transform_values(&:to_f)).to eq(
      "2026-04" => 1.25,
      "2026-05" => 3.5
    )
  end

  it "groups by a whitelisted custom timestamp column" do
    llm_api_call_model.create!(
      provider: "openai",
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15,
      total_cost: 1.25,
      tags: "{}",
      tracked_at: Time.utc(2026, 4, 18),
      created_at: Time.utc(2026, 5, 2),
      updated_at: Time.utc(2026, 5, 2)
    )

    expect(
      llm_api_call_model.group_by_period(:day, column: :created_at).sum(:total_cost).transform_values(&:to_f)
    ).to eq("2026-05-02" => 1.25)
  end

  it "builds PostgreSQL period grouping SQL" do
    allow(llm_api_call_model.connection).to receive(:adapter_name).and_return("PostgreSQL")

    day_sql = llm_api_call_model.group_by_period(:day).to_sql
    month_sql = llm_api_call_model.group_by_period(:month).to_sql

    expect(day_sql).to include("TO_CHAR(DATE_TRUNC('day'")
    expect(day_sql).to include("'YYYY-MM-DD'")
    expect(month_sql).to include("TO_CHAR(DATE_TRUNC('month'")
    expect(month_sql).to include("'YYYY-MM'")
  end

  it "builds MySQL period grouping SQL" do
    allow(llm_api_call_model.connection).to receive(:adapter_name).and_return("Mysql2")

    day_sql = llm_api_call_model.group_by_period(:day).to_sql
    month_sql = llm_api_call_model.group_by_period(:month).to_sql

    expect(day_sql).to include("DATE_FORMAT")
    expect(day_sql).to include("'%Y-%m-%d'")
    expect(month_sql).to include("DATE_FORMAT")
    expect(month_sql).to include("'%Y-%m'")
  end

  it "composes period grouping with other scopes" do
    tracked_at = Time.now.utc

    llm_api_call_model.create!(
      provider: "openai",
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15,
      total_cost: 1.25,
      tags: "{}",
      tracked_at: tracked_at
    )
    llm_api_call_model.create!(
      provider: "anthropic",
      model: "claude-haiku-4-5",
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15,
      total_cost: 3.5,
      tags: "{}",
      tracked_at: tracked_at
    )

    result = llm_api_call_model.this_month.where(provider: "openai").group_by_period(:day).sum(:total_cost)

    expect(result.transform_values(&:to_f)).to eq(tracked_at.strftime("%Y-%m-%d") => 1.25)
  end

  it "rejects invalid periods before building SQL" do
    expect do
      llm_api_call_model.group_by_period("day; DROP TABLE llm_api_calls")
    end.to raise_error(ArgumentError, /invalid period/)
  end

  it "rejects invalid period columns before building SQL" do
    expect do
      llm_api_call_model.group_by_period(:day, column: "tracked_at; DROP TABLE llm_api_calls")
    end.to raise_error(ArgumentError, /invalid period column/)
  end

  it "supports safe tag keys with dots and dashes" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0,
      "feature.name" => "chat"
    )
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o-mini",
      input_tokens: 1_000,
      output_tokens: 0,
      "feature.name" => "summarizer"
    )

    expect(llm_api_call_model.cost_by_tag("feature.name")).to eq(
      "chat" => 0.0025,
      "summarizer" => 0.00015
    )
  end

  it "composes tag grouping with other scopes" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0,
      feature: "chat"
    )
    LlmCostTracker.track(
      provider: :anthropic,
      model: "claude-haiku-4-5",
      input_tokens: 1_000,
      output_tokens: 0,
      feature: "chat"
    )

    result = llm_api_call_model.this_month.where(provider: "openai").group_by_tag("feature").sum(:total_cost)

    expect(result.transform_values(&:to_f)).to eq("chat" => 0.0025)
  end

  it "rejects invalid tag keys before building SQL" do
    expect do
      llm_api_call_model.group_by_tag("feature; DROP TABLE llm_api_calls")
    end.to raise_error(ArgumentError, /invalid tag key/)
  end

  it "filters by tag convenience scopes" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      user_id: 42,
      feature: "chat"
    )

    expect(llm_api_call_model.by_tag("user_id", 42).count).to eq(1)
    expect(llm_api_call_model.by_tag("feature", "chat").count).to eq(1)
    expect(llm_api_call_model.by_tag("feature", "summarizer").count).to eq(0)
  end

  it "escapes text tag queries so wildcard values do not over-match" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      feature: "100%"
    )
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      feature: "1000"
    )

    expect(llm_api_call_model.by_tag("feature", "100%").count).to eq(1)
  end

  it "filters calls with and without known pricing" do
    LlmCostTracker.configure do |config|
      config.storage_backend = :active_record
      config.unknown_pricing_behavior = :ignore
    end

    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5
    )
    LlmCostTracker.track(
      provider: :openai,
      model: "unknown-chat-model",
      input_tokens: 10,
      output_tokens: 5
    )

    expect(llm_api_call_model.with_cost.count).to eq(1)
    expect(llm_api_call_model.without_cost.count).to eq(1)
    expect(llm_api_call_model.unknown_pricing.first.model).to eq("unknown-chat-model")
  end

  it "aggregates latency by model and provider" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      latency_ms: 100
    )
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      latency_ms: 300
    )

    expect(llm_api_call_model.with_latency.count).to eq(2)
    expect(llm_api_call_model.average_latency_ms).to eq(200.0)
    expect(llm_api_call_model.latency_by_model).to eq("gpt-4o" => 200.0)
    expect(llm_api_call_model.latency_by_provider).to eq("openai" => 200.0)
  end

  it "does not write latency when an older schema has no latency column" do
    ActiveRecord::Base.connection.remove_column(:llm_api_calls, :latency_ms)
    llm_api_call_model.reset_column_information

    expect do
      LlmCostTracker.track(
        provider: :openai,
        model: "gpt-4o",
        input_tokens: 10,
        output_tokens: 5,
        latency_ms: 123
      )
    end.not_to raise_error
    expect(llm_api_call_model.first.attributes).not_to have_key("latency_ms")
  end

  it "warns and does not raise when ActiveRecord storage fails" do
    require "llm_cost_tracker/storage/active_record_store"

    allow(LlmCostTracker::Storage::ActiveRecordStore).to receive(:save)
      .and_raise(ActiveRecord::StatementInvalid, "database down")

    expect do
      LlmCostTracker.track(
        provider: :openai,
        model: "gpt-4o",
        input_tokens: 10,
        output_tokens: 5
      )
    end.to output(/Storage failed; tracking event was not persisted: ActiveRecord::StatementInvalid: database down/)
      .to_stderr
  end

  it "returns daily cost keys as strings across adapters" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5
    )

    expect(llm_api_call_model.daily_costs.keys).to all(be_a(String))
  end

  it "detects text tag columns as the fallback storage path" do
    expect(llm_api_call_model.tags_json_column?).to be false
  end

  it "builds a JSONB containment query for PostgreSQL JSONB tag columns" do
    allow(llm_api_call_model).to receive_messages(tags_json_column?: true, tags_jsonb_column?: true,
                                                  tags_mysql_json_column?: false)

    sql = llm_api_call_model.by_tags(user_id: 42, feature: "chat").to_sql

    expect(sql).to include("tags @>")
    expect(sql).to include('{"user_id":"42","feature":"chat"}')
  end

  it "builds a JSON_CONTAINS query for MySQL JSON tag columns" do
    allow(llm_api_call_model).to receive_messages(tags_json_column?: true, tags_jsonb_column?: false,
                                                  tags_mysql_json_column?: true)

    sql = llm_api_call_model.by_tags(user_id: 42, feature: "chat").to_sql

    expect(sql).to include("JSON_CONTAINS(tags,")
    expect(sql).to include('{"user_id":"42","feature":"chat"}')
  end

  it "does not double-count the latest event in budget callbacks" do
    budget_data = nil

    LlmCostTracker.configure do |config|
      config.storage_backend = :active_record
      config.monthly_budget = 0.001
      config.on_budget_exceeded = ->(data) { budget_data = data }
    end

    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )

    expect(llm_api_call_model.total_cost).to eq(0.0025)
    expect(budget_data[:monthly_total]).to eq(0.0025)
  end

  it "notifies once when :notify first crosses the monthly budget" do
    budget_totals = []

    LlmCostTracker.configure do |config|
      config.storage_backend = :active_record
      config.monthly_budget = 0.004
      config.on_budget_exceeded = ->(data) { budget_totals << data[:monthly_total] }
    end

    3.times do
      LlmCostTracker.track(
        provider: :openai,
        model: "gpt-4o",
        input_tokens: 1_000,
        output_tokens: 0
      )
    end

    expect(budget_totals).to eq([0.005])
  end

  it "blocks before a request when the ActiveRecord monthly budget is exhausted" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )

    LlmCostTracker.configure do |config|
      config.storage_backend = :active_record
      config.monthly_budget = 0.001
      config.budget_exceeded_behavior = :block_requests
    end

    expect do
      LlmCostTracker::Tracker.enforce_budget!
    end.to raise_error(LlmCostTracker::BudgetExceededError) { |error|
      expect(error.monthly_total).to eq(0.0025)
      expect(error.budget).to eq(0.001)
    }
  end
end
