# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Parsers do
  describe ".find_for" do
    it "finds the built-in parser for matching request URLs" do
      expect(described_class.find_for("https://api.openai.com/v1/responses"))
        .to be_a(LlmCostTracker::Parsers::Openai)
    end
  end

  describe ".find_for_provider" do
    it "finds the OpenAI-compatible parser for configured provider names" do
      LlmCostTracker.configure do |config|
        config.openai_compatible_providers["llm.example.com"] = "internal_gateway"
      end

      parser = described_class.find_for_provider("internal_gateway")

      expect(parser).to be_a(LlmCostTracker::Parsers::OpenaiCompatible)
    end

    it "matches provider names case-insensitively" do
      expect(described_class.find_for_provider("OPENAI")).to be_a(LlmCostTracker::Parsers::Openai)
    end
  end
end
