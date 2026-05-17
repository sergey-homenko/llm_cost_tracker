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

    it "classifies dotted gpt-5 chat variants (5.1/5.2-chat-latest) as non-reasoning" do
      %w[gpt-5.1-chat-latest gpt-5.2-chat-latest gpt-5.4-chat-2026-01-01].each do |model|
        result = described_class.build_line_item(
          { "type" => "web_search_call", "id" => "ws_#{model}" },
          request: { tools: [{ type: "web_search_preview" }] },
          model: model
        )
        expect(result.kind).to eq(:web_search_preview_request_non_reasoning), "expected #{model} to be non-reasoning"
      end
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

  describe ".service_line_items_for" do
    it "captures a web-search line item when a Chat Completions response carries url_citation annotations, routed to the preview-non-reasoning rate for gpt-4o-search-preview" do
      response = {
        "id" => "chatcmpl_search_1",
        "model" => "gpt-4o-search-preview",
        "choices" => [{
          "message" => {
            "role" => "assistant",
            "annotations" => [{
              "type" => "url_citation",
              "url_citation" => { "url" => "https://example.com", "title" => "Example",
                                  "start_index" => 0, "end_index" => 10 }
            }]
          }
        }]
      }

      items = described_class.service_line_items_for(response, request: {}, model: "gpt-4o-search-preview")

      expect(items.size).to eq(1)
      expect(items.first.kind).to eq(:web_search_preview_request_non_reasoning)
      expect(items.first.provider_item_id).to eq("chatcmpl_search_1")
      expect(items.first.provider_field).to eq("choices.message.annotations.url_citation")
    end

    it "returns no service line items for a Chat Completions response without url_citation annotations" do
      response = {
        "id" => "chatcmpl_plain_1",
        "model" => "gpt-4o",
        "choices" => [{ "message" => { "role" => "assistant", "content" => "hello" } }]
      }

      expect(described_class.service_line_items_for(response, request: {}, model: "gpt-4o")).to eq([])
    end

    it "still parses Responses-API output items unchanged" do
      response = {
        "id" => "resp_1",
        "output" => [{ "type" => "web_search_call", "id" => "ws_1", "action" => { "type" => "search" } }]
      }

      items = described_class.service_line_items_for(response, request: {}, model: "gpt-4o")

      expect(items.size).to eq(1)
      expect(items.first.kind).to eq(:web_search_request)
    end
  end

  describe "Chat Completions search model routing" do
    it "routes gpt-4o-search-preview to the preview-non-reasoning rate even without a tools array" do
      result = described_class.build_line_item(
        { "type" => "web_search_call", "id" => "ws_search_pre" },
        request: {},
        model: "gpt-4o-search-preview"
      )
      expect(result.kind).to eq(:web_search_preview_request_non_reasoning)
    end

    it "routes gpt-4o-mini-search-preview to the preview-non-reasoning rate" do
      result = described_class.build_line_item(
        { "type" => "web_search_call", "id" => "ws_search_mini" },
        request: {},
        model: "gpt-4o-mini-search-preview"
      )
      expect(result.kind).to eq(:web_search_preview_request_non_reasoning)
    end

    it "routes gpt-5-search-api to the preview-reasoning rate (gpt-5 family is reasoning)" do
      result = described_class.build_line_item(
        { "type" => "web_search_call", "id" => "ws_search_5" },
        request: {},
        model: "gpt-5-search-api"
      )
      expect(result.kind).to eq(:web_search_preview_request_reasoning)
    end

    it "leaves a plain gpt-4o (no search model name, no preview tool) on the standard web_search_request rate" do
      result = described_class.build_line_item(
        { "type" => "web_search_call", "id" => "ws_plain" },
        request: {},
        model: "gpt-4o"
      )
      expect(result.kind).to eq(:web_search_request)
    end
  end

  describe "annotation type discrimination" do
    it "does not capture a service line item when the only annotation type is file_citation" do
      response = {
        "id" => "chatcmpl_file_1",
        "choices" => [{
          "message" => {
            "role" => "assistant",
            "annotations" => [{
              "type" => "file_citation",
              "file_citation" => { "file_id" => "file_abc", "index" => 0 }
            }]
          }
        }]
      }

      expect(described_class.service_line_items_for(response, request: {}, model: "gpt-4o")).to eq([])
    end
  end
end
