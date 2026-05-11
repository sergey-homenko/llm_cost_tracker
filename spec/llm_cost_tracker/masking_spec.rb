# frozen_string_literal: true

require "spec_helper"
require "llm_cost_tracker/masking"

RSpec.describe LlmCostTracker::Masking do
  describe ".mask_value" do
    it "returns the value as a string when the key is not sensitive" do
      expect(described_class.mask_value(:provider, "openai")).to eq("openai")
    end

    it "masks the trailing four characters of a sensitive value" do
      expect(described_class.mask_value(:provider_api_key_id, "sk-live-1234567890ABCDEF")).to eq("***CDEF")
    end

    it "masks provider_project_id (added in v0.9)" do
      expect(described_class.mask_value(:provider_project_id, "proj_abcdef")).to eq("***cdef")
    end

    it "leaves short sensitive values unmasked rather than exposing one or two characters" do
      expect(described_class.mask_value(:provider_api_key_id, "ab")).to eq("ab")
    end

    it "accepts string keys equivalently to symbols" do
      expect(described_class.mask_value("provider_workspace_id", "wrkspc_abcdef")).to eq("***cdef")
    end
  end

  describe ".mask_hash" do
    it "masks sensitive keys and leaves non-sensitive keys untouched" do
      hash = { provider: "openai", provider_api_key_id: "sk-live-1234567890ABCDEF", model: "gpt-4o" }
      expect(described_class.mask_hash(hash)).to eq(
        provider: "openai",
        provider_api_key_id: "***CDEF",
        model: "gpt-4o"
      )
    end

    it "recurses into nested hashes" do
      hash = { outer: { provider_workspace_id: "wrkspc_abcdef", note: "kept" } }
      expect(described_class.mask_hash(hash)).to eq(
        outer: { provider_workspace_id: "***cdef", note: "kept" }
      )
    end

    it "recurses into arrays of hashes and leaves scalar entries unchanged" do
      hash = { items: [{ provider_api_key_id: "sk-AAAA1111" }, "scalar", { other: "kept" }] }
      expect(described_class.mask_hash(hash)).to eq(
        items: [{ provider_api_key_id: "***1111" }, "scalar", { other: "kept" }]
      )
    end

    it "returns non-hash input unchanged" do
      expect(described_class.mask_hash("not-a-hash")).to eq("not-a-hash")
    end
  end

  describe ".format_attribution" do
    it "renders empty string for nil/empty attribution" do
      expect(described_class.format_attribution(nil)).to eq("")
      expect(described_class.format_attribution({})).to eq("")
    end

    it "joins masked key=value pairs with the default separator" do
      summary = described_class.format_attribution(
        { provider_api_key_id: "sk-live-ABCDEF", model: "gpt-4o" }
      )
      expect(summary).to eq("provider_api_key_id=***CDEF, model=gpt-4o")
    end
  end
end
