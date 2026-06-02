# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Pricing::PriceKey do
  describe ".build" do
    it "composes mode and above-context prefixes" do
      expect(described_class.build("input")).to eq("input")
      expect(described_class.build("input", mode: "batch")).to eq("batch_input")
      expect(described_class.build("input", above_context: true)).to eq("above_context_input")
      expect(described_class.build("input", mode: "batch", above_context: true)).to eq("above_context_batch_input")
    end
  end

  describe ".parse_dimension_key" do
    it "resolves every non-token dimension key to itself, unshadowed by an earlier suffix match" do
      LlmCostTracker::Usage::Catalog.all.reject(&:token_key).each do |dimension|
        expect(described_class.parse_dimension_key(dimension.key)).to eq([dimension, nil]),
          -> { "#{dimension.key} is shadowed by an earlier dimension" }
      end
    end
  end

  describe ".price_key_for" do
    it "round-trips keys built for token dimensions" do
      LlmCostTracker::Usage::Catalog.token_priced.each do |dimension|
        key = described_class.build(dimension.key, mode: "batch", above_context: true)
        expect(described_class.price_key_for(key)).to eq(key)
      end
    end

    it "maps a bare dimension key to itself" do
      expect(described_class.price_key_for("input")).to eq("input")
    end

    it "returns nil for an unknown key" do
      expect(described_class.price_key_for("totally_unknown")).to be_nil
    end
  end
end
