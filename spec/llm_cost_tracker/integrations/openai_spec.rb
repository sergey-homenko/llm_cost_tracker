# frozen_string_literal: true

require "spec_helper"

require "llm_cost_tracker/integrations/openai"

RSpec.describe LlmCostTracker::Integrations::Openai do
  ResponseStruct = Struct.new(:output, keyword_init: true)
  OutputItemStruct = Struct.new(:type, :id, :status, :container_id, :action, keyword_init: true)
  ActionStruct = Struct.new(:type, keyword_init: true)
  ChatResponseStruct = Struct.new(:id, :choices, :model, keyword_init: true)
  ChatChoiceStruct = Struct.new(:message, keyword_init: true)
  ChatMessageStruct = Struct.new(:role, :content, :annotations, keyword_init: true)
  ChatAnnotationStruct = Struct.new(:type, :url_citation, keyword_init: true)

  describe ".service_line_items_from" do
    it "coerces Symbol type accessors from the OpenAI SDK to strings so hosted-tool charges are not silently dropped" do
      response = ResponseStruct.new(
        output: [
          OutputItemStruct.new(
            type: :web_search_call,
            id: "ws_sym_1",
            status: :completed,
            container_id: nil,
            action: ActionStruct.new(type: :search)
          ),
          OutputItemStruct.new(
            type: :file_search_call,
            id: "fs_sym_1",
            status: :completed,
            container_id: nil,
            action: nil
          )
        ]
      )

      items = described_class.service_line_items_from(response)

      expect(items.map(&:kind)).to contain_exactly(:web_search_request, :file_search_call)
    end

    it "emits SDK-shaped web_search_call as a billable line item" do
      response = ResponseStruct.new(
        output: [
          OutputItemStruct.new(
            type: "web_search_call",
            id: "ws_1",
            status: "completed",
            container_id: nil,
            action: ActionStruct.new(type: "search")
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
      response = ResponseStruct.new(
        output: [
          OutputItemStruct.new(
            type: "web_search_call",
            id: "ws_1",
            status: "completed",
            container_id: nil,
            action: ActionStruct.new(type: "preview")
          )
        ]
      )

      expect(described_class.service_line_items_from(response)).to be_empty
    end

    it "deduplicates container_session items by container_id across the SDK output" do
      response = ResponseStruct.new(
        output: [
          OutputItemStruct.new(type: "code_interpreter_call", id: "ci_a", status: "completed",
                               container_id: "container-42", action: nil),
          OutputItemStruct.new(type: "code_interpreter_call", id: "ci_b", status: "completed",
                               container_id: "container-42", action: nil)
        ]
      )

      items = described_class.service_line_items_from(response)

      expect(items.size).to eq(1)
      expect(items.first.kind).to eq(:container_session)
      expect(items.first.provider_item_id).to eq("container-42")
    end

    it "ignores nil items and items without a recognized type" do
      response = ResponseStruct.new(
        output: [
          nil,
          OutputItemStruct.new(type: "reasoning", id: "r_1", status: "completed",
                               container_id: nil, action: nil)
        ]
      )

      expect(described_class.service_line_items_from(response)).to be_empty
    end

    it "returns [] when the response has no output collection" do
      response = ResponseStruct.new(output: nil)

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
      response = ResponseStruct.new(
        output: [
          OutputItemStruct.new(
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

    it "captures a web_search line item from an SDK Chat Completions response with url_citation annotations" do
      response = ChatResponseStruct.new(
        id: "chatcmpl_sdk_1",
        model: "gpt-4o-search-preview",
        choices: [
          ChatChoiceStruct.new(message: ChatMessageStruct.new(
            role: "assistant",
            content: "hi",
            annotations: [ChatAnnotationStruct.new(type: "url_citation",
                                                   url_citation: { url: "https://example.com" })]
          ))
        ]
      )

      items = described_class.service_line_items_from(response, request: { model: "gpt-4o-search-preview" })

      expect(items.size).to eq(1)
      expect(items.first.kind).to eq(:web_search_preview_request_non_reasoning)
      expect(items.first.provider_item_id).to eq("chatcmpl_sdk_1")
      expect(items.first.provider_field).to eq("choices.message.annotations.url_citation")
    end

    it "does not capture a service line item for an SDK Chat Completions response without url_citation annotations" do
      response = ChatResponseStruct.new(
        id: "chatcmpl_sdk_2",
        model: "gpt-4o",
        choices: [ChatChoiceStruct.new(message: ChatMessageStruct.new(role: "assistant", content: "hi",
                                                                       annotations: nil))]
      )

      expect(described_class.service_line_items_from(response)).to eq([])
    end
  end

  describe ".normalize_sdk_args" do
    it "passes args through when at least one positional is present" do
      expect(described_class.normalize_sdk_args([{ a: 1 }], {})).to eq([{ a: 1 }])
    end

    it "wraps kwargs as a single positional hash when only kwargs were given (explicit splat)" do
      expect(described_class.normalize_sdk_args([], { model: "x" })).to eq([{ model: "x" }])
    end

    it "returns empty args when nothing was given" do
      expect(described_class.normalize_sdk_args([], {})).to eq([])
    end
  end
end
