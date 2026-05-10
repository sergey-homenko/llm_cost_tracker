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
      expect(described_class.build_line_item({ "type" => "reasoning", "id" => "r_1" })).to be_nil
    end

    it "build_line_item dispatches web_search_call to the preview-non-reasoning component when the request used the preview tool with a non-reasoning model" do
      result = described_class.build_line_item(
        { "type" => "web_search_call", "id" => "ws_1" },
        request: { tools: [{ type: "web_search_preview" }] },
        model: "gpt-4o"
      )
      expect(result.kind).to eq(:web_search_preview_request_non_reasoning)
    end

    it "build_line_item dispatches web_search_call to the preview-reasoning component when the request used the preview tool with a reasoning model" do
      result = described_class.build_line_item(
        { "type" => "web_search_call", "id" => "ws_2" },
        request: { tools: [{ type: "web_search_preview" }] },
        model: "gpt-5-mini"
      )
      expect(result.kind).to eq(:web_search_preview_request_reasoning)
    end

    it "build_line_item keeps the standard web_search_request component when the request did not use the preview tool" do
      result = described_class.build_line_item(
        { "type" => "web_search_call", "id" => "ws_3" },
        request: { tools: [{ type: "web_search" }] },
        model: "gpt-4o"
      )
      expect(result.kind).to eq(:web_search_request)
    end

    it "classifies gpt-5-chat-latest as non-reasoning even though it starts with gpt-5" do
      result = described_class.build_line_item(
        { "type" => "web_search_call", "id" => "ws_chat" },
        request: { tools: [{ type: "web_search_preview" }] },
        model: "gpt-5-chat-latest"
      )
      expect(result.kind).to eq(:web_search_preview_request_non_reasoning)
    end

    it "classifies o-series double-digit reasoning models" do
      result = described_class.build_line_item(
        { "type" => "web_search_call", "id" => "ws_o10" },
        request: { tools: [{ type: "web_search_preview" }] },
        model: "o10"
      )
      expect(result.kind).to eq(:web_search_preview_request_reasoning)
    end
  end
end
