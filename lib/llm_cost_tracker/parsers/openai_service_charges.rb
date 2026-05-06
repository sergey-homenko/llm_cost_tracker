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

      private

      def openai_service_line_items(response)
        output_items = {}
        Array(response["output"]).each { |item| openai_store_output_item(output_items, item) }
        openai_output_items_to_line_items(output_items.values)
      end

      def openai_stream_service_line_items(events)
        output_items = {}
        each_event_data(events) do |data|
          Array(data.dig("response", "output")).each { |item| openai_store_output_item(output_items, item) }
          openai_store_output_item(output_items, data["item"])
        end
        openai_output_items_to_line_items(output_items.values)
      end

      def openai_store_output_item(output_items, item)
        return unless item.is_a?(Hash)
        return unless openai_billable_output_item?(item)

        component = RESPONSE_OUTPUT_COMPONENTS[item["type"]]
        key = if component == :container_session && item["container_id"]
                "#{component}:#{item['container_id']}"
              else
                item["id"] || "#{item['type']}:#{output_items.length}"
              end
        output_items[key] = item
      end

      def openai_output_items_to_line_items(output_items)
        output_items.filter_map do |item|
          component_key = RESPONSE_OUTPUT_COMPONENTS[item["type"]]
          next unless component_key

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
            details: openai_service_line_item_details(item)
          )
        end
      end

      def openai_service_line_item_details(item)
        {
          "status" => item["status"],
          "action_type" => item.dig("action", "type"),
          "container_id" => item["container_id"]
        }.compact
      end

      def openai_billable_output_item?(item)
        component = RESPONSE_OUTPUT_COMPONENTS[item["type"]]
        return false unless component
        return true unless component == :web_search_request

        action_type = item.dig("action", "type")
        action_type.nil? || action_type == "search"
      end
    end
  end
end
