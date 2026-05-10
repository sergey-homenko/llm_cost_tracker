# frozen_string_literal: true

require_relative "../billing/line_item"

module LlmCostTracker
  module Parsers
    module OpenaiServiceCharges
      RESPONSE_OUTPUT_COMPONENTS = {
        "web_search_call" => :web_search_request,
        "file_search_call" => :file_search_call,
        "code_interpreter_call" => :container_session
      }.freeze

      REASONING_MODEL_PATTERNS = [
        /\Agpt-5(\b|[\d.-])/i,
        /\Ao\d+(\b|[\d.-])/i
      ].freeze
      NON_REASONING_GPT5_PATTERN = /\Agpt-5-chat\b/i
      private_constant :NON_REASONING_GPT5_PATTERN

      module_function

      def line_items_from_output(output_items, request: nil, model: nil)
        deduped = {}
        Array(output_items).each { |item| store_output_item(deduped, item) }
        deduped.values.filter_map { |item| build_line_item(item, request: request, model: model) }
      end

      def billable?(item)
        return false unless item.is_a?(Hash)

        component = RESPONSE_OUTPUT_COMPONENTS[item["type"]]
        return false unless component
        return true unless component == :web_search_request

        action_type = item.dig("action", "type")
        action_type.nil? || action_type == "search"
      end

      def store_output_item(output_items, item)
        return unless billable?(item)

        component = RESPONSE_OUTPUT_COMPONENTS[item["type"]]
        key = if component == :container_session && item["container_id"]
                "#{component}:#{item['container_id']}"
              else
                item["id"] || "#{item['type']}:#{output_items.length}"
              end
        output_items[key] = item
      end

      def build_line_item(item, request: nil, model: nil)
        return nil unless item.is_a?(Hash)

        component_key = component_key_for(item, request: request, model: model)
        return nil unless component_key

        provider_item_id = if component_key == :container_session
                             item["container_id"] || item["id"]
                           else
                             item["id"]
                           end
        Billing::LineItem.build(
          component_key: component_key,
          quantity: 1,
          cost_status: Billing::CostStatus::UNKNOWN,
          pricing_basis: :provider_usage,
          provider_field: "response.output.#{item['type']}",
          provider_item_id: provider_item_id,
          details: line_item_details(item)
        )
      end

      def component_key_for(item, request:, model:)
        component = RESPONSE_OUTPUT_COMPONENTS[item["type"]]
        return component unless component == :web_search_request
        return component unless web_search_preview_used?(request)

        reasoning_model?(model) ? :web_search_preview_request_reasoning : :web_search_preview_request_non_reasoning
      end

      def web_search_preview_used?(request)
        tools = request && (request[:tools] || request["tools"])
        return false unless tools.respond_to?(:each)

        tools.any? do |tool|
          type = tool.is_a?(Hash) ? (tool[:type] || tool["type"]) : tool
          type.to_s.include?("web_search_preview")
        end
      end

      def reasoning_model?(model)
        return false unless model

        name = model.to_s.split("/", 2).last
        return false if NON_REASONING_GPT5_PATTERN.match?(name)

        REASONING_MODEL_PATTERNS.any? { |pattern| pattern.match?(name) }
      end

      def line_item_details(item)
        {
          "status" => item["status"],
          "action_type" => item.dig("action", "type"),
          "container_id" => item["container_id"]
        }.compact
      end

      def openai_service_line_items(response, request: nil)
        line_items_from_output(response["output"], request: request, model: response["model"])
      end

      def openai_stream_service_line_items(events, request: nil, model: nil)
        output_items = []
        each_event_data(events) do |data|
          output_items.concat(Array(data.dig("response", "output")))
          output_items << data["item"] if data["item"]
        end
        line_items_from_output(output_items, request: request, model: model)
      end
    end
  end
end
