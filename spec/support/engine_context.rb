# frozen_string_literal: true

module LlmCostTrackerEngineContext
  def app
    Rails.application
  end

  def get(path, params: {})
    query = params.empty? ? "" : "?#{URI.encode_www_form(params)}"
    Rack::MockRequest.new(app).get("#{path}#{query}")
  end

  def post(path, params: {})
    Rack::MockRequest.new(app).post(
      path,
      input: URI.encode_www_form(params),
      "CONTENT_TYPE" => "application/x-www-form-urlencoded"
    )
  end

  def create_call(**overrides)
    attrs = {
      provider: "openai",
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      cache_read_input_tokens: 0,
      cache_write_input_tokens: 0,
      cache_write_extended_input_tokens: 0,
      audio_input_tokens: 0,
      audio_output_tokens: 0,
      hidden_output_tokens: 0,
      total_cost: 1.0,
      cost_status: LlmCostTracker::Billing::CostStatus::COMPLETE,
      pricing_snapshot: { "schema_version" => 1, "source" => "test", "rates" => {} },
      latency_ms: 100,
      provider_response_id: nil,
      tags: {},
      tracked_at: Time.now.utc
    }.merge(overrides)
    attrs[:total_tokens] = attrs.fetch(:input_tokens) +
                           attrs.fetch(:cache_read_input_tokens) +
                           attrs.fetch(:cache_write_input_tokens) +
                           attrs.fetch(:cache_write_extended_input_tokens) +
                           attrs.fetch(:audio_input_tokens) +
                           attrs.fetch(:output_tokens) +
                           attrs.fetch(:audio_output_tokens)
    raw_tags = attrs.delete(:tags)

    call = LlmCostTracker::Call.create!(attrs)
    create_call_tag_rows(call, raw_tags)
    LlmCostTracker::Ledger::Rollups.increment!([call])
    call
  end

end

RSpec.shared_context "with mounted llm cost tracker engine" do
  require "active_record"
  require "json"
  require "llm_cost_tracker/ledger"
  require "rack/mock"

  include LlmCostTrackerEngineContext

  around do |example|
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = false
    example.run
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  before do
    Rails.logger = Logger.new(nil)
    establish_database_connection!
    create_lct_tables!
    LlmCostTracker::Call.reset_column_information
    LlmCostTracker::CallLineItem.reset_column_information
    LlmCostTracker::CallTag.reset_column_information
    LlmCostTracker::CallRollup.reset_column_information
    LlmCostTracker::Ingestion::InboxEntry.reset_column_information
    LlmCostTracker::Ingestion::Lease.reset_column_information
    LlmCostTracker::Dashboard::SetupState.reset!

    LlmCostTracker.configuration.ingestion = :async
    LlmCostTracker.configuration.cache_rollups = true
  end

  after do
    disconnect_database!
  end
end
