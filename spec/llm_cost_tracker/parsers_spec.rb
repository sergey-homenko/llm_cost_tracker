# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Parsers do
  describe ".find_for" do
    it "finds the built-in parser for matching request URLs" do
      expect(described_class.find_for("https://api.openai.com/v1/responses"))
        .to be_a(LlmCostTracker::Providers::Openai::Parser)
    end

    it "routes Azure OpenAI URLs to the Azure parser" do
      url = "https://myresource.openai.azure.com/openai/deployments/gpt4o-prod/chat/completions"
      expect(described_class.find_for(url)).to be_a(LlmCostTracker::Providers::Azure::Parser)
    end
  end

  describe ".find_for_provider" do
    it "finds the OpenAI-compatible parser for configured provider names" do
      LlmCostTracker.configure do |config|
        config.openai_compatible_providers["llm.example.com"] = "internal_gateway"
      end

      parser = described_class.find_for_provider("internal_gateway")

      expect(parser).to be_a(LlmCostTracker::Providers::OpenaiCompatible::Parser)
    end

    it "finds default OpenAI-compatible providers before configuration is finalized" do
      expect(described_class.find_for_provider("openrouter")).to be_a(LlmCostTracker::Providers::OpenaiCompatible::Parser)
    end

    it "matches provider names case-insensitively" do
      expect(described_class.find_for_provider("OPENAI")).to be_a(LlmCostTracker::Providers::Openai::Parser)
    end

    it "finds the Azure parser by the azure_openai provider name" do
      expect(described_class.find_for_provider("azure_openai")).to be_a(LlmCostTracker::Providers::Azure::Parser)
    end

    it "uses provider names from the current configuration" do
      LlmCostTracker.configure do |config|
        config.openai_compatible_providers["llm.example.com"] = "internal_gateway"
      end

      expect(described_class.find_for_provider("internal_gateway"))
        .to be_a(LlmCostTracker::Providers::OpenaiCompatible::Parser)
      expect(described_class.find_for_provider("INTERNAL_GATEWAY"))
        .to be_a(LlmCostTracker::Providers::OpenaiCompatible::Parser)

      LlmCostTracker.reset_configuration!
      LlmCostTracker.configure do |config|
        config.openai_compatible_providers["llm.example.com"] = "other_gateway"
      end

      expect(described_class.find_for_provider("internal_gateway")).to be_nil
      expect(described_class.find_for_provider("OTHER_GATEWAY"))
        .to be_a(LlmCostTracker::Providers::OpenaiCompatible::Parser)
    end
  end
end
