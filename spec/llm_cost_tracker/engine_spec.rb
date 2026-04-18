# frozen_string_literal: true

require "active_record"
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

  it "renders the mounted dashboard with an empty state" do
    response = get("/llm-costs")

    expect(response.status).to eq(200)
    expect(response.body).to include("LLM Costs")
    expect(response.body).to include("No LLM calls have been recorded yet.")
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
