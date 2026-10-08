# frozen_string_literal: true

require "spec_helper"
require "llm_cost_tracker/integrations/base"

RSpec.describe LlmCostTracker::Integrations::Base do
  describe "#stream_collector" do
    it "leaves the pricing mode to the stream parser" do
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

    it "lets callers pass a per-call provider override into enforce_budget!" do
      integration = Module.new do
        extend LlmCostTracker::Integrations::Base
        def self.integration_name = :ruby_llm
      end
      allow(LlmCostTracker.configuration).to receive(:instrumented?).and_return(true)
      allow(LlmCostTracker::Budget).to receive(:enforce!)

      integration.enforce_budget!(request: { model: "gpt-4o" }, provider: "openai")

      expect(LlmCostTracker::Budget).to have_received(:enforce!).with(
        provider: "openai", model: "gpt-4o", request: { model: "gpt-4o" }, tags: nil
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

    it "reads the SDK client's host, or none without a client or from an unparsable base_url" do
      client = Struct.new(:base_url)

      expect(integration.client_host(client.new("https://api.example.com/v1"))).to eq("api.example.com")
      expect(integration.client_host(client.new("https://exa mple.com"))).to be_nil
      expect(integration.client_host(nil)).to be_nil
    end

    it "hands back the SDK stream untouched while the integration is not instrumented" do
      stream = Object.new

      expect(integration.wrap_stream([{ model: "gpt-4o" }], {}, collector: ->(request) { request }) { stream })
        .to be(stream)
    end
  end

  describe "patch targets" do
    def integration_patching(&targets)
      Module.new do
        extend LlmCostTracker::Integrations::Base

        def self.integration_name = :spec_sdk

        define_singleton_method(:patch_targets) { instance_exec(&targets) }
      end
    end

    before { stub_const("LlmCostTrackerSpecResource", Class.new { def create = :original }) }

    it "prepends each patch once and reports the integration installed only after install" do
      patch = Module.new { def create = [:patched, super] }
      integration = integration_patching { [patch_target("LlmCostTrackerSpecResource", with: patch)] }

      expect(integration.status.message).to eq("spec_sdk integration is enabled but not installed")
      2.times { integration.install }

      expect(LlmCostTrackerSpecResource.ancestors.count(patch)).to eq(1)
      expect(LlmCostTrackerSpecResource.new.create).to eq(%i[patched original])
      expect(integration.status).to have_attributes(status: :ok, message: "spec_sdk integration installed")
    end

    it "lists missing classes and methods, except optional classes and targets that may lack the methods" do
      patch = Module.new { def stream = super }
      integration = integration_patching do
        [patch_target("LlmCostTrackerSpecResource", with: patch),
         patch_target("LlmCostTrackerSpecResource", with: patch, skip_when_methods_missing: true),
         patch_target("LlmCostTrackerSpecMissing", with: patch),
         patch_target("LlmCostTrackerSpecMissing", with: patch, optional: true)]
      end
      message = "spec_sdk integration cannot be installed: LlmCostTrackerSpecResource#stream is not available; " \
                "LlmCostTrackerSpecMissing is not loaded"

      expect(integration.status).to have_attributes(status: :warn, message: message)
      expect { integration.install }.to raise_error(LlmCostTracker::Error, message)
      expect(integration.patch_target("LlmCostTrackerSpecMissing", with: patch)).not_to be_installed
    end
  end
end
