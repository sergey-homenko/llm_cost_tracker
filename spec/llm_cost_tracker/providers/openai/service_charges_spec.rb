# frozen_string_literal: true

require "spec_helper"
require "llm_cost_tracker/providers/openai/service_charges"

RSpec.describe LlmCostTracker::Providers::Openai::ServiceCharges do
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
      expect(result.kind).to eq("web_search_preview_request_non_reasoning")
    end

    it "build_line_item dispatches web_search_call to the preview-reasoning component when the request used the preview tool with a reasoning model" do
      result = described_class.build_line_item(
        { "type" => "web_search_call", "id" => "ws_2" },
        request: { tools: [{ type: "web_search_preview" }] },
        model: "gpt-5-mini"
      )
      expect(result.kind).to eq("web_search_preview_request_reasoning")
    end

    it "build_line_item keeps the standard web_search_request component when the request did not use the preview tool" do
      result = described_class.build_line_item(
        { "type" => "web_search_call", "id" => "ws_3" },
        request: { tools: [{ type: "web_search" }] },
        model: "gpt-4o"
      )
      expect(result.kind).to eq("web_search_request")
    end

    it "emits an unpriced line item per completed image_generation_call because Responses usage leaves the image charge out" do
      output = [
        { "type" => "image_generation_call", "id" => "ig_1", "status" => "completed" },
        { "type" => "image_generation_call", "id" => "ig_2", "status" => "failed" },
        { "type" => "image_generation_call", "id" => "ig_3", "status" => "in_progress" }
      ]
      items = described_class.line_items_from_output(output)

      expect(items.map { |item| [item.kind, item.provider_item_id, item.cost_status] })
        .to eq([["image_generation_call", "ig_1", LlmCostTracker::Charges::CostStatus::UNKNOWN]])
    end

    it "does not emit line items for computer_call / mcp_call because they bill through tokens, not a separate charge" do
      output = [
        { "type" => "computer_call", "id" => "cc_1", "status" => "completed" },
        { "type" => "mcp_call", "id" => "mcp_1", "status" => "completed" }
      ]
      expect(described_class.line_items_from_output(output)).to be_empty
    end

    it "classifies gpt-5-chat-latest as non-reasoning even though it starts with gpt-5" do
      result = described_class.build_line_item(
        { "type" => "web_search_call", "id" => "ws_chat" },
        request: { tools: [{ type: "web_search_preview" }] },
        model: "gpt-5-chat-latest"
      )
      expect(result.kind).to eq("web_search_preview_request_non_reasoning")
    end

    it "classifies dotted gpt-5 chat variants (5.1/5.2-chat-latest) as non-reasoning" do
      %w[gpt-5.1-chat-latest gpt-5.2-chat-latest gpt-5.4-chat-2026-01-01].each do |model|
        result = described_class.build_line_item(
          { "type" => "web_search_call", "id" => "ws_#{model}" },
          request: { tools: [{ type: "web_search_preview" }] },
          model: model
        )
        expect(result.kind).to eq("web_search_preview_request_non_reasoning"), "expected #{model} to be non-reasoning"
      end
    end

    it "classifies o-series double-digit reasoning models" do
      result = described_class.build_line_item(
        { "type" => "web_search_call", "id" => "ws_o10" },
        request: { tools: [{ type: "web_search_preview" }] },
        model: "o10"
      )
      expect(result.kind).to eq("web_search_preview_request_reasoning")
    end
  end

  describe ".service_line_items_for" do
    it "returns no service line items for a Chat Completions response from a non-search model, even with url_citation annotations" do
      response = {
        "id" => "chatcmpl_plain_1",
        "model" => "gpt-4o",
        "choices" => [{
          "message" => {
            "role" => "assistant",
            "annotations" => [{ "type" => "url_citation", "url_citation" => { "url" => "https://example.com" } }]
          }
        }]
      }

      expect(described_class.service_line_items_for(response, request: {}, model: "gpt-4o")).to eq([])
    end

    it "captures the per-call fee for a Chat Completions search-preview model even when the response carries no url_citation annotations" do
      response = {
        "id" => "chatcmpl_no_cite_1",
        "model" => "gpt-4o-search-preview",
        "choices" => [{ "message" => { "role" => "assistant", "content" => "nothing relevant" } }]
      }

      items = described_class.service_line_items_for(response, request: {}, model: "gpt-4o-search-preview")

      expect(items.size).to eq(1)
      expect(items.first.kind).to eq("web_search_preview_request_non_reasoning")
      expect(items.first.provider_item_id).to eq("chatcmpl_no_cite_1")
      expect(items.first.provider_field).to eq("request.model")
    end

    it "still parses Responses-API output items unchanged" do
      response = {
        "id" => "resp_1",
        "output" => [{ "type" => "web_search_call", "id" => "ws_1", "action" => { "type" => "search" } }]
      }

      items = described_class.service_line_items_for(response, request: {}, model: "gpt-4o")

      expect(items.size).to eq(1)
      expect(items.first.kind).to eq("web_search_request")
    end
  end

  describe "Chat Completions search model routing" do
    it "routes gpt-4o-search-preview to the preview-non-reasoning rate even without a tools array" do
      result = described_class.build_line_item(
        { "type" => "web_search_call", "id" => "ws_search_pre" },
        request: {},
        model: "gpt-4o-search-preview"
      )
      expect(result.kind).to eq("web_search_preview_request_non_reasoning")
    end

    it "routes gpt-4o-mini-search-preview to the preview-non-reasoning rate" do
      result = described_class.build_line_item(
        { "type" => "web_search_call", "id" => "ws_search_mini" },
        request: {},
        model: "gpt-4o-mini-search-preview"
      )
      expect(result.kind).to eq("web_search_preview_request_non_reasoning")
    end

    it "routes gpt-5-search-api to the preview-reasoning rate (gpt-5 family is reasoning)" do
      result = described_class.build_line_item(
        { "type" => "web_search_call", "id" => "ws_search_5" },
        request: {},
        model: "gpt-5-search-api"
      )
      expect(result.kind).to eq("web_search_preview_request_reasoning")
    end

    it "leaves a plain gpt-4o (no search model name, no preview tool) on the standard web_search_request rate" do
      result = described_class.build_line_item(
        { "type" => "web_search_call", "id" => "ws_plain" },
        request: {},
        model: "gpt-4o"
      )
      expect(result.kind).to eq("web_search_request")
    end
  end

  describe ".billed_line_items" do
    def billed(usage)
      described_class.billed_line_items(usage).map { |item| [item.cost.to_s("F"), item.provider_field] }
    end

    it "reads xAI's cost_in_usd_ticks exactly, at 10^10 ticks to the dollar" do
      expect(billed(cost_in_usd_ticks: 37_756_000)).to eq([["0.0037756", "usage.cost_in_usd_ticks"]])
      expect(billed(cost_in_usd_ticks: 1)).to eq([["0.0000000001", "usage.cost_in_usd_ticks"]])
    end

    it "reads Perplexity's usage.cost.total_cost" do
      cost = { input_tokens_cost: 0.00001, output_tokens_cost: 0.00001, request_cost: 0.005, total_cost: 0.00502 }

      expect(billed(cost: cost)).to eq([["0.00502", "usage.cost.total_cost"]])
    end

    it "skips the zero total_cost Perplexity stream chunks carry before the last one" do
      expect(billed(cost: { input_tokens_cost: 0, output_tokens_cost: 0, total_cost: 0 })).to eq([])
    end

    it "keeps a numeric usage.cost ahead of the other fields" do
      expect(billed(cost: 0.0123, cost_in_usd_ticks: 1)).to eq([["0.0123", "usage.cost"]])
    end

    it "ignores billed amounts that are not numbers instead of raising" do
      malformed = [{ cost_in_usd_ticks: "37756000" }, { cost_in_usd_ticks: { value: 1 } }, { cost: [0.02] },
                   { cost: { total_cost: "0.02" } }, { cost: { input_tokens_cost: 0.01 } }, { cost: "0.02" }, {}]

      expect(malformed.map { |usage| billed(usage) }).to all(eq([]))
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
