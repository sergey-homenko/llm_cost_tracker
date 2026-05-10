# frozen_string_literal: true

require "spec_helper"
require "llm_cost_tracker/ledger/tags/encoding"

RSpec.describe LlmCostTracker::Ledger::Tags::Encoding do
  describe ".encode" do
    it "stringifies scalars" do
      expect(described_class.encode("hello")).to eq("hello")
      expect(described_class.encode(42)).to eq("42")
      expect(described_class.encode(true)).to eq("true")
      expect(described_class.encode(false)).to eq("false")
      expect(described_class.encode(nil)).to eq("")
      expect(described_class.encode(:admin)).to eq("admin")
    end

    it "JSON-encodes Hash values with stringified keys and values" do
      expect(described_class.encode({ user_id: 42 })).to eq('{"user_id":"42"}')
      expect(described_class.encode("user_id" => "42")).to eq('{"user_id":"42"}')
      expect(described_class.encode({ user_id: 42, role: :admin })).to eq('{"user_id":"42","role":"admin"}')
    end

    it "JSON-encodes Array values" do
      expect(described_class.encode([1, 2, 3])).to eq('["1","2","3"]')
      expect(described_class.encode([{ id: 1 }, { id: 2 }])).to eq('[{"id":"1"},{"id":"2"}]')
    end

    it "recurses through nested mixes" do
      value = { tags: [{ name: "foo", count: 3 }, { name: "bar", count: 0 }] }
      expect(described_class.encode(value)).to eq('{"tags":[{"name":"foo","count":"3"},{"name":"bar","count":"0"}]}')
    end

    it "produces matching strings for equivalent symbol-keyed and string-keyed hashes" do
      expect(described_class.encode(user_id: 42)).to eq(described_class.encode("user_id" => 42))
    end
  end

  describe ".normalize_value" do
    it "leaves Hash structure intact (does not JSON.generate)" do
      expect(described_class.normalize_value(user_id: 42)).to eq("user_id" => "42")
      expect(described_class.normalize_value([{ a: 1 }])).to eq([{ "a" => "1" }])
    end

    it "stringifies scalars" do
      expect(described_class.normalize_value(42)).to eq("42")
      expect(described_class.normalize_value(:admin)).to eq("admin")
    end
  end
end
