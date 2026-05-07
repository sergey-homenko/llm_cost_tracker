# frozen_string_literal: true

require "spec_helper"
require "llm_cost_tracker/parsers/openai_service_charges"

RSpec.describe LlmCostTracker::Parsers::OpenaiServiceCharges do
  describe ".line_items_from_output" do
    it "returns no line items for an empty output" do
      expect(described_class.line_items_from_output([])).to eq([])
    end

    it "skips items whose type is not a recognized billable component" do
      output = [{ "type" => "reasoning", "id" => "r_1" }]

      expect(described_class.line_items_from_output(output)).to eq([])
    end

    it "treats nil items defensively" do
      expect(described_class.line_items_from_output([nil])).to eq([])
    end

    it "billable? returns false for non-hash inputs" do
      expect(described_class.billable?("string")).to be false
      expect(described_class.billable?(nil)).to be false
    end

    it "build_line_item returns nil when the type is not in the registry" do
      expect(described_class.build_line_item("type" => "reasoning", "id" => "r_1")).to be_nil
    end
  end
end
