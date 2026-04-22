# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::PriceSync::ModelCatalog do
  describe ".guess_provider" do
    it "infers providers from canonical model ids" do
      expect(described_class.guess_provider("gpt-4o")).to eq(:openai)
      expect(described_class.guess_provider("claude-sonnet-4-6")).to eq(:anthropic)
      expect(described_class.guess_provider("gemini-2.5-flash")).to eq(:gemini)
    end
  end

  describe ".resolve_from_litellm" do
    it "matches canonical aliases and provider-prefixed ids" do
      payload = {
        "gpt-4o" => {},
        "gemini/gemini-2.5-flash" => {},
        "claude-sonnet-4.6" => {}
      }

      expect(described_class.resolve_from_litellm("gpt-4o-2024-05-13", payload)).to eq("gpt-4o")
      expect(described_class.resolve_from_litellm("gemini-2.5-flash", payload)).to eq("gemini/gemini-2.5-flash")
      expect(described_class.resolve_from_litellm("claude-sonnet-4-6", payload)).to eq("claude-sonnet-4.6")
    end
  end

  describe ".resolve_from_openrouter" do
    it "matches provider-prefixed ids and anthropic dotted versions" do
      payload = {
        "openai/gpt-4o" => {},
        "google/gemini-2.5-flash" => {},
        "anthropic/claude-sonnet-4.6" => {}
      }

      expect(described_class.resolve_from_openrouter("gpt-4o-2024-05-13", payload)).to eq("openai/gpt-4o")
      expect(described_class.resolve_from_openrouter("gemini-2.5-flash", payload)).to eq("google/gemini-2.5-flash")
      expect(described_class.resolve_from_openrouter("claude-sonnet-4-6", payload)).to eq("anthropic/claude-sonnet-4.6")
    end
  end
end
