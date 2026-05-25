# frozen_string_literal: true

require "spec_helper"
require "llm_cost_tracker/providers/anthropic/tier_classification"

RSpec.describe LlmCostTracker::Providers::Anthropic::TierClassification do
  describe ".data_residency_geo?" do
    it "matches the documented us inference geo, case-insensitively" do
      expect(described_class.data_residency_geo?("us")).to be true
      expect(described_class.data_residency_geo?("US")).to be true
    end

    it "rejects other geos" do
      %w[eu apac jp gb].each do |geo|
        expect(described_class.data_residency_geo?(geo)).to be false
      end
    end

    it "is false for nil and empty" do
      expect(described_class.data_residency_geo?(nil)).to be false
      expect(described_class.data_residency_geo?("")).to be false
    end
  end

  describe ".standard_equivalent_tier?" do
    it "preserves Priority Tier as its own mode so committed pricing isn't billed at standard rates" do
      expect(described_class.standard_equivalent_tier?("priority")).to be false
    end

    it "treats standard / standard_only as themselves" do
      expect(described_class.standard_equivalent_tier?("standard")).to be true
      expect(described_class.standard_equivalent_tier?("standard_only")).to be true
    end

    it "rejects batch tier and unknown tiers" do
      expect(described_class.standard_equivalent_tier?("batch")).to be false
      expect(described_class.standard_equivalent_tier?("flex")).to be false
      expect(described_class.standard_equivalent_tier?(nil)).to be false
    end
  end
end
