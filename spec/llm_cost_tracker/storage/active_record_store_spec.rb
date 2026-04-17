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
        t.decimal :input_cost, precision: 12, scale: 8
        t.decimal :output_cost, precision: 12, scale: 8
        t.decimal :total_cost, precision: 12, scale: 8
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

  it "lazy-loads the ActiveRecord store and persists events" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 500,
      user_id: 42,
      feature: "chat"
    )

    expect(LlmCostTracker::LlmApiCall.count).to eq(1)

    call = LlmCostTracker::LlmApiCall.first
    expect(call.provider).to eq("openai")
    expect(call.model).to eq("gpt-4o")
    expect(call.total_cost.to_f).to eq(0.0075)
    expect(call.parsed_tags).to include("user_id" => "42", "feature" => "chat")
  end

  it "finds stringified numeric tags through by_tag" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      user_id: 42
    )

    expect(LlmCostTracker::LlmApiCall.by_tag("user_id", "42").count).to eq(1)
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

    expect(LlmCostTracker::LlmApiCall.total_cost).to eq(0.0025)
    expect(budget_data[:monthly_total]).to eq(0.0025)
  end
end
