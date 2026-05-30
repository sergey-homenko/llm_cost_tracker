# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Configuration do
  let(:config) { described_class.new }

  describe "ingestion enum" do
    it "defaults to :inline" do
      expect(config.ingestion).to eq(:inline)
    end

    it "accepts :async" do
      config.ingestion = :async
      expect(config.ingestion).to eq(:async)
    end

    it "raises for unknown values" do
      expect { config.ingestion = :bogus }.to raise_error(LlmCostTracker::Error, /Unknown ingestion/)
    end

    it "normalizes nil back to :inline" do
      config.ingestion = :async
      config.ingestion = nil
      expect(config.ingestion).to eq(:inline)
    end
  end

  describe "pricing_overrides=" do
    it "raises a friendly error for a non-numeric price value" do
      expect { config.pricing_overrides = { "demo" => { "input" => nil } } }
        .to raise_error(LlmCostTracker::Error, /invalid pricing_overrides/)
    end
  end
end
