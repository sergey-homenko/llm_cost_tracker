# frozen_string_literal: true

require "spec_helper"
require "llm_cost_tracker/providers/openai/hosts"

RSpec.describe LlmCostTracker::Providers::Openai::Hosts do
  describe ".data_residency?" do
    it "matches regional subdomains under api.openai.com" do
      %w[us.api.openai.com gb.api.openai.com sg.api.openai.com].each do |host|
        expect(described_class.data_residency?(host)).to be true
      end
    end

    it "does not match the canonical api.openai.com" do
      expect(described_class.data_residency?("api.openai.com")).to be false
    end

    it "does not match Azure or non-OpenAI hosts" do
      expect(described_class.data_residency?("tenant.openai.azure.com")).to be false
      expect(described_class.data_residency?("api.anthropic.com")).to be false
    end
  end
end
