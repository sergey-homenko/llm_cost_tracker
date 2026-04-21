# frozen_string_literal: true

module LlmCostTrackerEngineContext
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
        t.boolean :stream, null: false, default: false
        t.string :usage_source
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
end

RSpec.shared_context "with mounted llm cost tracker engine" do
  require "active_record"
  require "json"
  require "llm_cost_tracker/llm_api_call"
  require "rack/mock"

  include LlmCostTrackerEngineContext

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
end
