# frozen_string_literal: true

require "spec_helper"
require "bigdecimal"
require "llm_cost_tracker/pricing/estimator"

RSpec.describe LlmCostTracker::Pricing::Estimator do
  describe ".char_count" do
    it "sums string lengths recursively through hash values and arrays" do
      request = {
        messages: [
          { role: "system", content: "hello" },
          { role: "user", content: [{ type: "text", text: "world!" }] }
        ],
        temperature: 0.7
      }
      expect(described_class.char_count(request)).to eq("hello".length + "system".length +
                                                       "world!".length + "text".length +
                                                       "user".length)
    end

    it "returns 0 for empty/missing payload" do
      expect(described_class.char_count({})).to eq(0)
      expect(described_class.char_count(nil)).to eq(0)
      expect(described_class.char_count([])).to eq(0)
    end

    it "ignores non-string scalars" do
      expect(described_class.char_count({ a: 42, b: true, c: nil })).to eq(0)
    end
  end

  describe ".call" do
    it "returns BigDecimal cost for a known model" do
      request = { messages: [{ role: "user", content: "a" * 400 }] }
      cost = described_class.call(provider: "openai", model: "gpt-4o-mini", request: request)
      expect(cost).to be_a(BigDecimal)
      expect(cost).to be > 0
    end

    it "returns 0 when the payload is empty" do
      cost = described_class.call(provider: "openai", model: "gpt-4o-mini", request: {})
      expect(cost).to eq(BigDecimal("0"))
    end

    it "returns nil when the model has no pricing entry" do
      request = { messages: [{ role: "user", content: "a" * 400 }] }
      cost = described_class.call(provider: "openai", model: "nonexistent-model-xyz", request: request)
      expect(cost).to be_nil
    end
  end
end
