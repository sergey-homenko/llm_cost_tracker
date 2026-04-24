# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Doctor do
  it "reports the default non-ActiveRecord setup without failing" do
    checks = described_class.call

    expect(checks).to include(
      have_attributes(status: :ok, name: "configuration"),
      have_attributes(status: :ok, name: "storage"),
      have_attributes(status: :warn, name: "prices")
    )
    expect(described_class.healthy?).to be true
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
