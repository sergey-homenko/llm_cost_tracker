# frozen_string_literal: true

module LlmCostTrackerEngineContext
  def app
    Rails.application
  end

  def get(path)
    Rack::MockRequest.new(app).get(path)
  end

  def create_call(**overrides)
    attrs = {
      provider: "openai",
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      cache_read_input_tokens: 0,
      cache_write_input_tokens: 0,
      cache_write_1h_input_tokens: 0,
      hidden_output_tokens: 0,
      total_cost: 1.0,
      cost_status: LlmCostTracker::Billing::CostStatus::COMPLETE,
      pricing_snapshot: { "schema" => 1, "source" => "test", "rates" => {} },
      latency_ms: 100,
      provider_response_id: nil,
      tags: {},
      tracked_at: Time.now.utc
    }.merge(overrides)
    attrs[:total_tokens] = attrs.fetch(:input_tokens) +
                           attrs.fetch(:cache_read_input_tokens) +
                           attrs.fetch(:cache_write_input_tokens) +
                           attrs.fetch(:cache_write_1h_input_tokens) +
                           attrs.fetch(:output_tokens)
    attrs[:tags] = tags_for_database(attrs.fetch(:tags))

    call = LlmCostTracker::Ledger::Call.create!(attrs)
    LlmCostTracker::Ledger::Rollups.increment!(call)
    call
  end
end

RSpec.shared_context "with mounted llm cost tracker engine" do
  require "active_record"
  require "json"
  require "llm_cost_tracker/ledger"
  require "rack/mock"

  include LlmCostTrackerEngineContext

  before do
    Rails.logger = Logger.new(nil)
    establish_database_connection!
    create_lct_tables!
    LlmCostTracker::Ledger::Call.reset_column_information
    LlmCostTracker::Ledger::ServiceCharge.reset_column_information
    LlmCostTracker::Ledger::Period::Total.reset_column_information
    LlmCostTracker::Ingestion::Event.reset_column_information
    LlmCostTracker::Ingestion::Lease.reset_column_information
  end

  after do
    disconnect_database!
  end
end
