# frozen_string_literal: true

require "spec_helper"

ENV["RAILS_ENV"] ||= "test"

require_relative "../dummy/config/environment"

RSpec.describe LlmCostTracker::CaptureVerifier do
  it "reports log storage as verifiable through logs" do
    checks = described_class.call

    expect(checks).to include(
      have_attributes(status: :ok, name: "tracking", message: "enabled"),
      have_attributes(status: :ok, name: "storage", message: include("log backend"))
    )
    expect(described_class.healthy?(checks)).to be true
  end

  it "fails when tracking is disabled" do
    LlmCostTracker.configure { |config| config.enabled = false }

    checks = described_class.call

    expect(checks).to include(
      have_attributes(status: :error, name: "tracking", message: include("disabled"))
    )
    expect(described_class.healthy?(checks)).to be false
  end

  it "fails when custom storage has no callable" do
    LlmCostTracker.configure { |config| config.storage_backend = :custom }

    check = described_class.call.find { |item| item.name == "storage" }

    expect(check).to have_attributes(status: :error, message: include("custom_storage"))
  end

  context "with ActiveRecord storage" do
    include_context "with mounted llm cost tracker engine"

    it "verifies a manual capture event inside a rollback" do
      checks = described_class.call

      expect(checks).to include(
        have_attributes(status: :ok, name: "active_record capture", message: include("persisted inside rollback"))
      )
      expect(LlmCostTracker::LlmApiCall.where("provider_response_id LIKE ?", "lct_verify_%")).to be_empty
    end
  end
end
