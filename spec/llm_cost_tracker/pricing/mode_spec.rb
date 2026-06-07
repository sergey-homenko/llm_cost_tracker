# frozen_string_literal: true

require "spec_helper"
require "llm_cost_tracker/pricing/mode"

RSpec.describe LlmCostTracker::Pricing::Mode do
  describe ".merge" do
    it "keeps host-derived data_residency from the request hint when provider only echoes the tier" do
      expect(described_class.merge("priority", "priority_data_residency")).to eq("priority_data_residency")
    end

    it "lets the provider override the tier while preserving host-derived data_residency" do
      expect(described_class.merge("standard", "priority_data_residency")).to eq("data_residency")
    end

    it "falls back to the request hint when the provider returns no pricing mode" do
      expect(described_class.merge(nil, "batch_data_residency")).to eq("batch_data_residency")
    end

    it "uses the provider mode when the request had no hint" do
      expect(described_class.merge("batch", nil)).to eq("batch")
    end

    it "drops standard tier tokens (normalize collapses them)" do
      expect(described_class.merge("standard", nil)).to be_nil
    end
  end

  describe "modifier registries" do
    it "treats on_demand as one token so a real on_demand tier is not falsely warned" do
      expect(LlmCostTracker::Logging).not_to receive(:warn)
      expect(described_class.normalize("on_demand")).to eq("on_demand")
    end

    it "keeps host-derived modifiers a subset of known modifiers" do
      expect(described_class::HOST_DERIVED_MODIFIERS - described_class::KNOWN_MODIFIERS).to be_empty
    end

    it "tokenizes by matching the known-modifier vocabulary, so multi-word modifiers stay whole" do
      expect(described_class.tokenize("batch_data_residency")).to eq(%w[batch data_residency])
      expect(described_class.tokenize("on_demand")).to eq(%w[on_demand])
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
      expect(described_class.normalize("priority")).to eq("priority")
      expect(described_class.normalize(:priority)).to eq("priority")
      expect(described_class.normalize("data-residency")).to eq("data_residency")
    end

    it "matches provider tier strings regardless of case" do
      expect(described_class.normalize("PRIORITY")).to eq("priority")
      expect(described_class.normalize(:Priority)).to eq("priority")
      expect(described_class.normalize("Standard")).to be_nil
    end

    it "returns nil for nil and unparseable inputs" do
      expect(described_class.normalize(nil)).to be_nil
      expect(described_class.normalize("")).to be_nil
    end

    it "warns once per unrecognized pricing_mode token so misspellings (e.g. `:bach` for `:batch`) don't silently land as cost_status: unknown" do
      allow(LlmCostTracker::Logging).to receive(:warn)
      described_class.instance_variable_set(:@warned_tokens, nil)

      described_class.normalize("bach")
      described_class.normalize("bach")

      expect(LlmCostTracker::Logging).to have_received(:warn).once
        .with(include("bach").and(include("cost_status: unknown")))
    end

    it "recognizes OpenAI's `scale` enterprise tier and Anthropic's `priority` tier without warning" do
      allow(LlmCostTracker::Logging).to receive(:warn)
      described_class.instance_variable_set(:@warned_tokens, nil)

      expect(described_class.normalize("scale")).to eq("scale")
      expect(described_class.normalize("priority")).to eq("priority")
      expect(LlmCostTracker::Logging).not_to have_received(:warn)
    end

    it "treats Gemini's default `unspecified` service tier as standard (returns nil)" do
      allow(LlmCostTracker::Logging).to receive(:warn)
      described_class.instance_variable_set(:@warned_tokens, nil)

      expect(described_class.normalize("unspecified")).to be_nil
      expect(LlmCostTracker::Logging).not_to have_received(:warn)
    end
  end

  describe ".permutations_for" do
    it "returns the canonical form for a single-modifier mode" do
      expect(described_class.permutations_for(:priority)).to eq(["priority"])
    end

    it "enumerates every ordering for compound modes" do
      perms = described_class.permutations_for("batch_data_residency_priority")

      expect(perms).to contain_exactly(
        "batch_data_residency_priority",
        "batch_priority_data_residency",
        "data_residency_batch_priority",
        "data_residency_priority_batch",
        "priority_batch_data_residency",
        "priority_data_residency_batch"
      )
    end

    it "preserves compound modifiers (data_residency) as one token" do
      expect(described_class.permutations_for(:data_residency)).to eq(["data_residency"])
    end

    it "treats hyphens as underscores" do
      expect(described_class.permutations_for("data-residency-priority"))
        .to contain_exactly("data_residency_priority", "priority_data_residency")
    end

    it "lowercases input modifiers" do
      expect(described_class.permutations_for("BATCH_PRIORITY"))
        .to contain_exactly("batch_priority", "priority_batch")
    end

    it "caps permutations for an unbounded token count to avoid a factorial blow-up" do
      mode = (1..13).map { |i| "m#{i}" }.join("_")
      expect(described_class.permutations_for(mode).size).to eq(1)
    end
  end

  describe ".compose" do
    it "joins tokens, dropping nils and duplicates" do
      expect(described_class.compose([:fast, nil, :fast, "data_residency"])).to eq("fast_data_residency")
    end

    it "preserves token order rather than sorting" do
      expect(described_class.compose([:priority, "data_residency"])).to eq("priority_data_residency")
    end

    it "returns nil when no tokens survive" do
      expect(described_class.compose([nil, nil])).to be_nil
      expect(described_class.compose([])).to be_nil
    end
  end
end
