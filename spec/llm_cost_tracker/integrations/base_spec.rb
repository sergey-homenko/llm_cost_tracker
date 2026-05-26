# frozen_string_literal: true

require "spec_helper"
require "llm_cost_tracker/integrations/base"

RSpec.describe LlmCostTracker::Integrations::Base do
  describe "#stream_collector default pricing_mode" do
    it "is nil when an integration does not override stream_pricing_mode" do
      integration = Module.new do
        extend LlmCostTracker::Integrations::Base

        def self.integration_name
          :test_integration
        end
      end

      collector = integration.stream_collector({ model: "test-model" })

      expect(collector.instance_variable_get(:@pricing_mode)).to be_nil
      expect(collector.provider).to eq("test_integration")
    end
  end

  describe ".provider DSL" do
    it "defaults to integration_name.to_s when no override is declared" do
      integration = Module.new do
        extend LlmCostTracker::Integrations::Base
        def self.integration_name = :gemini_ai
      end

      expect(integration.provider).to eq("gemini_ai")
    end

    it "returns the declared override when set via `provider :slug`" do
      integration = Module.new do
        extend LlmCostTracker::Integrations::Base
        def self.integration_name = :gemini_ai
        provider :gemini
      end

      expect(integration.provider).to eq("gemini")
    end

    it "lets callers pass a per-call provider override into enforce_budget!" do
      integration = Module.new do
        extend LlmCostTracker::Integrations::Base
        def self.integration_name = :ruby_llm
      end
      allow(LlmCostTracker.configuration).to receive(:instrumented?).and_return(true)
      allow(LlmCostTracker::Budget).to receive(:enforce!)

      integration.enforce_budget!(request: { model: "gpt-4o" }, provider: "openai")

      expect(LlmCostTracker::Budget).to have_received(:enforce!).with(
        provider: "openai", model: "gpt-4o", request: { model: "gpt-4o" }
      )
    end
  end

  describe ".request_params" do
    let(:integration) do
      Module.new do
        extend LlmCostTracker::Integrations::Base

        def self.integration_name
          :test
        end
      end
    end

    it "extracts a Hash positional argument unchanged" do
      params = integration.request_params([{ model: "gpt-4o", input: "x" }], {})
      expect(params["model"]).to eq("gpt-4o")
    end

    it "extracts an SDK request object that responds to to_h instead of returning empty params (would otherwise lose model context on typed SDK params)" do
      request_obj = Struct.new(:to_h_value).new({ model: "gpt-image-2", n: 2 }).tap do |s|
        s.define_singleton_method(:to_h) { @to_h_value || to_h_value }
      end
      params = integration.request_params([request_obj], {})
      expect(params["model"]).to eq("gpt-image-2")
      expect(params["n"]).to eq(2)
    end

    it "falls back to kwargs alone when the positional argument cannot be coerced to a Hash" do
      params = integration.request_params([Object.new], { temperature: 0.2 })
      expect(params["temperature"]).to eq(0.2)
    end
  end
end
