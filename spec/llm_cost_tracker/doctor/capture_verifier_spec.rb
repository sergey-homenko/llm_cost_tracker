# frozen_string_literal: true

require "spec_helper"

ENV["RAILS_ENV"] ||= "test"

require_relative "../../dummy/config/environment"

RSpec.describe LlmCostTracker::Doctor::CaptureVerifier do
  before do
    establish_database_connection!
  end

  after do
    disconnect_database!
  end

  it "reports missing ActiveRecord storage as a setup error" do
    checks = described_class.call

    expect(checks).to include(
      have_attributes(status: :ok, name: "tracking", message: "enabled"),
      have_attributes(status: :error, name: "active_record", message: include("llm_cost_tracker_calls table is missing"))
    )
    expect(described_class.healthy?(checks)).to be false
  end

  it "fails when tracking is disabled" do
    LlmCostTracker.configure { |config| config.enabled = false }

    checks = described_class.call

    expect(checks).to include(
      have_attributes(status: :error, name: "tracking", message: include("disabled"))
    )
    expect(described_class.healthy?(checks)).to be false
  end

  it "reports enabled SDK integration checks" do
    stub_const("OpenAI", Module.new)
    stub_const("OpenAI::VERSION", "0.59.0")
    stub_const("OpenAI::Resources", Module.new)
    stub_const("OpenAI::Resources::Chat", Module.new)
    stub_const("OpenAI::Resources::Responses", Class.new do
      def create(**); end

      def stream(**); end

      def stream_raw(**); end

      def retrieve_streaming(*); end
    end)
    stub_const("OpenAI::Resources::Chat::Completions", Class.new do
      def create(**); end

      def stream(**); end

      def stream_raw(**); end
    end)

    LlmCostTracker.configure { |config| config.instrument :openai }

    expect(described_class.call).to include(
      have_attributes(status: :ok, name: "sdk integration openai", message: "openai integration installed")
    )
  end

  context "with ActiveRecord storage" do
    include_context "with mounted llm cost tracker engine"

    it "verifies a manual capture event through the inline writer" do
      checks = described_class.call

      expect(checks).to include(
        have_attributes(status: :ok, name: "active_record capture", message: include("inline writer"))
      )
      expect(LlmCostTracker::Call.where("provider_response_id LIKE ?", "lct_verify_%")).to be_empty
    end

    it "verifies a manual capture event through the durable inbox when ingestion_adapter is :durable" do
      LlmCostTracker.configure { |config| config.ingestion_adapter = :durable }
      checks = described_class.call

      expect(checks).to include(
        have_attributes(status: :ok, name: "active_record capture", message: include("durable inbox"))
      )
      expect(LlmCostTracker::Call.where("provider_response_id LIKE ?", "lct_verify_%")).to be_empty
    end

    it "handles absent verification subscriptions without cleanup errors" do
      allow(LlmCostTracker::Ingestion).to receive(:subscribe_to_verification).and_return(nil)

      checks = described_class.call

      expect(checks).to include(
        have_attributes(status: :error, name: "active_record capture", message: include("notification"))
      )
      expect(LlmCostTracker::Call.where("provider_response_id LIKE ?", "lct_verify_%")).to be_empty
    end
  end
end
