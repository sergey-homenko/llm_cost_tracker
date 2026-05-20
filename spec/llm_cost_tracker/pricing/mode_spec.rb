# frozen_string_literal: true

require "spec_helper"
require "llm_cost_tracker/pricing/mode"

RSpec.describe LlmCostTracker::Pricing::Mode do
  describe ".merge" do
    it "keeps host-derived data_residency from the request hint when provider only echoes the tier" do
      expect(described_class.merge("priority", "priority_data_residency")).to eq(:priority_data_residency)
    end

    it "lets the provider override the tier while preserving host-derived data_residency" do
      expect(described_class.merge("standard", "priority_data_residency")).to eq(:data_residency)
    end

    it "falls back to the request hint when the provider returns no pricing mode" do
      expect(described_class.merge(nil, "batch_data_residency")).to eq(:batch_data_residency)
    end

    it "uses the provider mode when the request had no hint" do
      expect(described_class.merge("batch", nil)).to eq(:batch)
    end

    it "drops standard tier tokens (normalize collapses them)" do
      expect(described_class.merge("standard", nil)).to be_nil
    end
  end

  describe ".normalize" do
    it "treats standard provider aliases as default pricing" do
      expect(described_class.normalize("standard")).to be_nil
      expect(described_class.normalize("default")).to be_nil
      expect(described_class.normalize("auto")).to be_nil
      expect(described_class.normalize("standard_only")).to be_nil
      expect(described_class.normalize(" ")).to be_nil
    end

    it "keeps non-standard pricing modes" do
      expect(described_class.normalize("priority")).to eq(:priority)
      expect(described_class.normalize(:priority)).to eq(:priority)
      expect(described_class.normalize("data-residency")).to eq(:data_residency)
    end

    it "matches provider tier strings regardless of case" do
      expect(described_class.normalize("PRIORITY")).to eq(:priority)
      expect(described_class.normalize(:Priority)).to eq(:priority)
      expect(described_class.normalize("Standard")).to be_nil
    end

    it "returns nil for nil and unparseable inputs" do
      expect(described_class.normalize(nil)).to be_nil
      expect(described_class.normalize("")).to be_nil
    end
  end

  describe ".parse" do
    it "produces an empty mode for nil" do
      expect(described_class.parse(nil)).to be_empty
    end

    it "passes through an existing Mode value" do
      mode = described_class.new([:batch])
      expect(described_class.parse(mode)).to be(mode)
    end

    it "tokenises a single modifier" do
      expect(described_class.parse(:batch).modifiers).to eq([:batch])
    end

    it "preserves compound modifiers (data_residency) as one token" do
      expect(described_class.parse(:data_residency).modifiers).to eq([:data_residency])
    end

    it "splits compound modes and sorts modifiers canonically" do
      mode = described_class.parse("batch_data_residency")

      expect(mode.modifiers).to eq(%i[batch data_residency])
      expect(mode.canonical).to eq("batch_data_residency")
    end

    it "treats hyphens as underscores" do
      expect(described_class.parse("data-residency-priority").modifiers)
        .to eq(%i[data_residency priority])
    end

    it "lowercases input modifiers" do
      expect(described_class.parse("BATCH_PRIORITY").modifiers).to eq(%i[batch priority])
    end
  end

  describe "#permutations" do
    it "returns the canonical form for a single-modifier mode" do
      expect(described_class.parse(:priority).permutations).to eq(["priority"])
    end

    it "enumerates every ordering for compound modes" do
      perms = described_class.parse("batch_data_residency_priority").permutations

      expect(perms).to contain_exactly(
        "batch_data_residency_priority",
        "batch_priority_data_residency",
        "data_residency_batch_priority",
        "data_residency_priority_batch",
        "priority_batch_data_residency",
        "priority_data_residency_batch"
      )
    end
  end

  describe "value semantics" do
    it "is equal to a parsed mode with the same modifiers regardless of input order" do
      expect(described_class.parse("priority_batch")).to eq(described_class.parse("batch_priority"))
    end

    it "is hashable so modes can be used as a Set member" do
      modes = Set.new
      modes << described_class.parse("batch")
      modes << described_class.parse("batch")
      expect(modes.size).to eq(1)
    end

    it "exposes #include? for modifier lookups" do
      mode = described_class.parse("priority_data_residency")

      expect(mode.include?(:priority)).to be true
      expect(mode.include?(:batch)).to be false
    end

    it "is empty for the empty mode" do
      expect(described_class.parse(nil)).to be_empty
      expect(described_class.parse("")).to be_empty
    end

    it "round-trips through to_sym" do
      expect(described_class.parse("priority").to_sym).to eq(:priority)
      expect(described_class.parse(nil).to_sym).to be_nil
    end
  end
end
