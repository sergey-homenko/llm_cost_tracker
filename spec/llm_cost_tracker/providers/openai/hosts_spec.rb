# frozen_string_literal: true

require "spec_helper"
require "llm_cost_tracker/providers/openai/hosts"

RSpec.describe LlmCostTracker::Providers::Openai::Hosts do
  describe ".bedrock?" do
    it "matches the Bedrock Mantle and Runtime hosts the openai gem's Bedrock provider calls" do
      expect(%w[bedrock-mantle.us-west-2.api.aws bedrock-runtime.us-east-1.amazonaws.com
                bedrock-runtime-fips.us-east-1.amazonaws.com bedrock-runtime.cn-north-1.amazonaws.com.cn]
               .map { |host| described_class.bedrock?(host) }).to all(be true)
      expect(%w[api.openai.com bedrock.us-east-1.amazonaws.com].map { |host| described_class.bedrock?(host) })
        .to all(be false)
    end
  end

  describe ".data_residency?" do
    it "matches regional subdomains under api.openai.com" do
      %w[us.api.openai.com gb.api.openai.com sg.api.openai.com].each do |host|
        expect(described_class.data_residency?(host)).to be true
      end
    end

    it "tracks every OpenAI regional data-residency host" do
      %w[us eu au ca jp in sg kr gb ae].each do |region|
        expect(LlmCostTracker::Parsers.find_for("https://#{region}.api.openai.com/v1/responses"))
          .to be_a(LlmCostTracker::Providers::Openai::Parser), region
      end
    end

    it "does not match the canonical api.openai.com" do
      expect(described_class.data_residency?("api.openai.com")).to be false
    end

    it "matches the xAI and Mistral regional hosts but not their global ones" do
      expect(%w[us.api.x.ai api.eu.mistral.ai api.us.mistral.ai].map { |host| described_class.data_residency?(host) })
        .to all(be true)
      expect(%w[api.x.ai api.mistral.ai].map { |host| described_class.data_residency?(host) }).to all(be false)
    end

    it "does not match Azure or non-OpenAI hosts" do
      expect(described_class.data_residency?("tenant.openai.azure.com")).to be false
      expect(described_class.data_residency?("api.anthropic.com")).to be false
      expect(described_class.data_residency?("us-central1-aiplatform.googleapis.com")).to be false
    end
  end

  describe ".vertex_non_global?" do
    it "matches Vertex AI regional and multi-region hosts but not its global host or the Gemini API" do
      regional = %w[us-central1-aiplatform.googleapis.com europe-west4-aiplatform.googleapis.com
                    aiplatform.us.rep.googleapis.com aiplatform.eu.rep.googleapis.com]
      expect(regional.map { |host| described_class.vertex_non_global?(host) }).to all(be true)
      expect(%w[aiplatform.googleapis.com generativelanguage.googleapis.com us.api.openai.com]
               .map { |host| described_class.vertex_non_global?(host) }).to all(be false)
    end
  end
end
