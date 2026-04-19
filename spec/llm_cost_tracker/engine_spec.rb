# frozen_string_literal: true

require "active_record"
require "json"
require "llm_cost_tracker/engine_compatibility"
require "llm_cost_tracker/llm_api_call"
require "rack/mock"
require "spec_helper"

ENV["RAILS_ENV"] ||= "test"

require_relative "../dummy/config/environment"

RSpec.describe "LlmCostTracker::Engine" do
  before do
    Rails.logger = Logger.new(nil)
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    create_llm_api_calls_table
    LlmCostTracker::LlmApiCall.reset_column_information
    LlmCostTracker.configure { |config| config.storage_backend = :active_record }
  end

  after do
    ActiveRecord::Base.connection.disconnect!
  end

  def app
    Rails.application
  end

  def get(path)
    Rack::MockRequest.new(app).get(path)
  end

  def create_llm_api_calls_table
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
  end

  def create_call(**overrides)
    attrs = {
      provider: "openai",
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      total_cost: 1.0,
      latency_ms: 100,
      tags: {},
      tracked_at: Time.now.utc
    }.merge(overrides)
    attrs[:total_tokens] = attrs.fetch(:input_tokens) + attrs.fetch(:output_tokens)
    attrs[:tags] = attrs.fetch(:tags).to_json

    LlmCostTracker::LlmApiCall.create!(attrs)
  end

  it "renders the mounted dashboard with an empty state" do
    response = get("/llm-costs")

    expect(response.status).to eq(200)
    expect(response.body).to include("LLM Costs")
    expect(response.body).to include("No LLM calls yet")
  end

  it "renders overview stats, daily spend, top models, feature costs, and budget status" do
    LlmCostTracker.configure do |config|
      config.storage_backend = :active_record
      config.monthly_budget = 10.0
    end

    create_call(
      provider: "openai",
      model: "gpt-4o",
      total_cost: 2.0,
      latency_ms: 100,
      tags: { feature: "chat" },
      tracked_at: Time.now.utc
    )
    create_call(
      provider: "anthropic",
      model: "claude-haiku-4-5",
      total_cost: 3.0,
      latency_ms: 300,
      tags: { feature: "summarizer" },
      tracked_at: 1.day.ago
    )

    response = get("/llm-costs")

    expect(response.status).to eq(200)
    expect(response.body).to include("Total spend")
    expect(response.body).to include("$5.00")
    expect(response.body).to include("Avg latency")
    expect(response.body).to include("200ms")
    expect(response.body).to include("Monthly Budget")
    expect(response.body).to include("Soft monthly limit. Blocking is not atomic under concurrency.")
    expect(response.body).to include("Daily Spend")
    expect(response.body).to include("Top Models")
    expect(response.body).to include("gpt-4o")
    expect(response.body).to include("Cost By Feature")
    expect(response.body).to include("chat")
    expect(response.body).to include("summarizer")
    expect(response.body.index("summarizer")).to be < response.body.index("chat")
  end

  it "applies overview filters to stats and breakdowns" do
    create_call(
      provider: "openai",
      model: "gpt-4o",
      total_cost: 2.0,
      tags: { feature: "chat" },
      tracked_at: Time.now.utc
    )
    create_call(
      provider: "anthropic",
      model: "claude-haiku-4-5",
      total_cost: 3.0,
      tags: { feature: "summarizer" },
      tracked_at: Time.now.utc
    )

    response = get("/llm-costs?provider=openai")

    expect(response.status).to eq(200)
    expect(response.body).to include("$2.00")
    expect(response.body).not_to include("$5.00")
    expect(response.body).to include("gpt-4o")
    expect(response.body).not_to include("claude-haiku-4-5")
    expect(response.body).to include("chat")
    expect(response.body).not_to include("summarizer")
  end

  it "renders invalid filter errors as bad requests" do
    response = get("/llm-costs?tag[%3BDROP]=x")

    expect(response.status).to eq(400)
    expect(response.body).to include("Invalid filter")
    expect(response.body).to include("invalid tag key")
  end

  it "renders a setup state when the ledger table is missing" do
    ActiveRecord::Base.connection.drop_table(:llm_api_calls)
    LlmCostTracker::LlmApiCall.reset_column_information

    response = get("/llm-costs")

    expect(response.status).to eq(200)
    expect(response.body).to include("llm_api_calls")
    expect(response.body).to include("rails generate llm_cost_tracker:install")
  end

  it "rejects Rails versions below 7.1 for the Engine" do
    expect do
      LlmCostTracker::EngineCompatibility.check_rails_version!("7.0.8")
    end.to raise_error(LlmCostTracker::Error, "LlmCostTracker::Engine requires Rails 7.1+")
  end

  it "accepts Rails 7.1 for the Engine" do
    expect do
      LlmCostTracker::EngineCompatibility.check_rails_version!("7.1.0")
    end.not_to raise_error
  end
end
