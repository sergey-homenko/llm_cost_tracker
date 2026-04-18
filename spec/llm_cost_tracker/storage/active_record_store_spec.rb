# frozen_string_literal: true

require "spec_helper"
require "active_record"

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
        t.decimal :input_cost, precision: 20, scale: 8
        t.decimal :output_cost, precision: 20, scale: 8
        t.decimal :total_cost, precision: 20, scale: 8
        t.integer :latency_ms
        t.text :tags
        t.datetime :tracked_at, null: false

        t.timestamps
      end
    end

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
    expect(matching_calls.first.feature).to eq("chat")
  end

  it "filters by user and feature convenience scopes" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      user_id: 42,
      feature: "chat"
    )

    expect(llm_api_call_model.by_user(42).count).to eq(1)
    expect(llm_api_call_model.by_feature("chat").count).to eq(1)
    expect(llm_api_call_model.by_feature("summarizer").count).to eq(0)
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

    expect(llm_api_call_model.by_feature("100%").count).to eq(1)
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
    allow(llm_api_call_model).to receive(:latency_column?).and_return(false)

    expect do
      LlmCostTracker.track(
        provider: :openai,
        model: "gpt-4o",
        input_tokens: 10,
        output_tokens: 5,
        latency_ms: 123
      )
    end.not_to raise_error
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

  it "builds a JSONB containment query for JSON-backed tag columns" do
    allow(llm_api_call_model).to receive(:tags_json_column?).and_return(true)

    sql = llm_api_call_model.by_tags(user_id: 42, feature: "chat").to_sql

    expect(sql).to include("tags @>")
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
