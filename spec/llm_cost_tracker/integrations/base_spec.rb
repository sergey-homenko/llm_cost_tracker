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

      collector = integration.stream_collector(model: "test-model")

      expect(collector.instance_variable_get(:@pricing_mode)).to be_nil
      expect(collector.provider).to eq("test_integration")
    end
  end
end
