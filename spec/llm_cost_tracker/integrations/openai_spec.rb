# frozen_string_literal: true

require "spec_helper"
require "ostruct"

require "llm_cost_tracker/integrations/openai"

RSpec.describe LlmCostTracker::Integrations::Openai do
  describe ".service_line_items_from" do
    it "emits SDK-shaped web_search_call as a billable line item" do
      response = OpenStruct.new(
        output: [
          OpenStruct.new(
            type: "web_search_call",
            id: "ws_1",
            status: "completed",
            container_id: nil,
            action: OpenStruct.new(type: "search")
          )
        ]
      )

      items = described_class.service_line_items_from(response)

      expect(items.size).to eq(1)
      expect(items.first.kind).to eq(:web_search_request)
      expect(items.first.provider_item_id).to eq("ws_1")
      expect(items.first.details).to include("status" => "completed", "action_type" => "search")
    end

    it "skips web_search_call when action.type is not 'search'" do
      response = OpenStruct.new(
        output: [
          OpenStruct.new(
            type: "web_search_call",
            id: "ws_1",
            status: "completed",
            container_id: nil,
            action: OpenStruct.new(type: "preview")
          )
        ]
      )

      expect(described_class.service_line_items_from(response)).to be_empty
    end

    it "deduplicates container_session items by container_id across the SDK output" do
      response = OpenStruct.new(
        output: [
          OpenStruct.new(type: "code_interpreter_call", id: "ci_a", status: "completed",
                         container_id: "container-42", action: nil),
          OpenStruct.new(type: "code_interpreter_call", id: "ci_b", status: "completed",
                         container_id: "container-42", action: nil)
        ]
      )

      items = described_class.service_line_items_from(response)

      expect(items.size).to eq(1)
      expect(items.first.kind).to eq(:container_session)
      expect(items.first.provider_item_id).to eq("container-42")
    end

    it "ignores nil items and items without a recognized type" do
      response = OpenStruct.new(
        output: [
          nil,
          OpenStruct.new(type: "reasoning", id: "r_1", status: "completed",
                         container_id: nil, action: nil)
        ]
      )

      expect(described_class.service_line_items_from(response)).to be_empty
    end

    it "returns [] when the response has no output collection" do
      response = OpenStruct.new(output: nil)

      expect(described_class.service_line_items_from(response)).to eq([])
    end

    it "passes through hash output items unchanged" do
      response = {
        output: [
          { "type" => "file_search_call", "id" => "fs_1", "status" => "completed" }
        ]
      }

      items = described_class.service_line_items_from(response)

      expect(items.size).to eq(1)
      expect(items.first.kind).to eq(:file_search_call)
    end

    it "preserves hash actions on SDK-shaped items" do
      response = OpenStruct.new(
        output: [
          OpenStruct.new(
            type: "web_search_call",
            id: "ws_1",
            status: "completed",
            container_id: nil,
            action: { "type" => "search" }
          )
        ]
      )

      items = described_class.service_line_items_from(response)

      expect(items.first.details).to include("action_type" => "search")
    end
  end
end
