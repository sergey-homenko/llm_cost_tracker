# frozen_string_literal: true

require "spec_helper"
require "llm_cost_tracker/providers/openai/hosts"

RSpec.describe LlmCostTracker::Providers::Openai::Hosts do
  describe ".api?" do
    it "matches the canonical and regional OpenAI API hosts" do
      %w[api.openai.com us.api.openai.com eu.api.openai.com gb.api.openai.com].each do |host|
        expect(described_class.api?(host)).to be(true), "expected #{host} to be a known OpenAI host"
      end
    end

    it "is case-insensitive" do
      expect(described_class.api?("API.OpenAI.com")).to be true
    end

    it "rejects non-OpenAI hosts" do
      %w[api.anthropic.com tenant.openai.azure.com api.example.com].each do |host|
        expect(described_class.api?(host)).to be false
      end
    end
  end

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
