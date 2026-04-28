# frozen_string_literal: true

require "json"
require "spec_helper"
require "tempfile"

ENV["RAILS_ENV"] ||= "test"

require_relative "../dummy/config/environment"

RSpec.describe LlmCostTracker::Doctor do
  it "reports the default non-ActiveRecord setup without failing" do
    checks = described_class.call

    expect(checks).to include(
      have_attributes(status: :ok, name: "configuration"),
      have_attributes(status: :ok, name: "capture", message: include("Faraday middleware and manual capture")),
      have_attributes(status: :ok, name: "storage"),
      have_attributes(status: :warn, name: "prices")
    )
    expect(described_class.healthy?).to be true
  end

  it "warns when tracking is disabled" do
    LlmCostTracker.configure { |config| config.enabled = false }

    check = described_class.call.find { |item| item.name == "capture" }

    expect(check).to have_attributes(status: :warn, message: include("tracking is disabled"))
  end

  it "warns when the configured prices file is stale" do
    Tempfile.create(["llm-prices", ".json"]) do |file|
      file.write({
        metadata: { updated_at: "2026-01-01", currency: "USD", unit: "1M tokens" },
        models: { "custom-model" => { input: 1.0, output: 2.0 } }
      }.to_json)
      file.close

      LlmCostTracker.configure { |config| config.prices_file = file.path }

      check = described_class.call.find { |item| item.name == "prices" }

      expect(check.status).to eq(:warn)
      expect(check.message).to include("older than 30 days")
      expect(check.message).to include("llm_cost_tracker:prices:refresh")
    end
  end

  it "accepts a fresh configured prices file" do
    Tempfile.create(["llm-prices", ".json"]) do |file|
      file.write({
        metadata: { updated_at: Date.today.iso8601, currency: "USD", unit: "1M tokens" },
        models: { "custom-model" => { input: 1.0, output: 2.0 } }
      }.to_json)
      file.close

      LlmCostTracker.configure { |config| config.prices_file = file.path }

      check = described_class.call.find { |item| item.name == "prices" }

      expect(check.status).to eq(:ok)
      expect(check.message).to include("updated_at=#{Date.today.iso8601}")
    end
  end

  context "with ActiveRecord storage" do
    include_context "with mounted llm cost tracker engine"

    it "reports table, column, period total, and call status" do
      checks = described_class.call

      expect(checks).to include(
        have_attributes(status: :ok, name: "llm_api_calls"),
        have_attributes(status: :ok, name: "llm_api_calls columns"),
        have_attributes(status: :warn, name: "period totals"),
        have_attributes(status: :warn, name: "tracked calls")
      )
    end

    it "reports recorded calls" do
      create_call(model: "gpt-4o")

      check = described_class.call.find { |item| item.name == "tracked calls" }

      expect(check.status).to eq(:ok)
      expect(check.message).to include("1 recorded")
    end
  end
end
