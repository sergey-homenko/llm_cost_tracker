# frozen_string_literal: true

require "spec_helper"
require "llm_cost_tracker/providers/azure/hosts"

RSpec.describe LlmCostTracker::Providers::Azure::Hosts do
  describe ".openai?" do
    it "matches the {resource}.openai.azure.com host pattern, case-insensitively" do
      %w[acme.openai.azure.com my-prod.openai.azure.com Tenant.OpenAI.Azure.Com].each do |host|
        expect(described_class.openai?(host)).to be(true), "expected #{host} to be an Azure OpenAI host"
      end
    end

    it "matches the Foundry {resource}.services.ai.azure.com host pattern" do
      %w[acme.services.ai.azure.com my-prod.services.ai.azure.com Tenant.Services.AI.Azure.Com].each do |host|
        expect(described_class.openai?(host)).to be(true), "expected #{host} to be an Azure Foundry host"
      end
    end

    it "rejects non-Azure OpenAI hosts" do
      [
        "api.openai.com",
        "us.api.openai.com",
        "tenant.cognitiveservices.azure.com",
        "openai.azure.com",
        "services.ai.azure.com"
      ].each do |host|
        expect(described_class.openai?(host)).to be(false), "expected #{host} to not match"
      end
    end

    it "is false for nil and empty" do
      expect(described_class.openai?(nil)).to be false
      expect(described_class.openai?("")).to be false
    end
  end
end
