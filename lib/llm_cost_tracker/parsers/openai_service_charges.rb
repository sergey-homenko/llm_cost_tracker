# frozen_string_literal: true

require_relative "../billing/service_charge"

module LlmCostTracker
  module Parsers
    module OpenaiServiceCharges
      RESPONSE_OUTPUT_COMPONENTS = {
        "web_search_call" => :web_search_request,
        "file_search_call" => :file_search_call,
        "code_interpreter_call" => :container_session
      }.freeze

      private

      def openai_service_charges(response)
        output_items = {}
        Array(response["output"]).each { |item| openai_store_output_item(output_items, item) }
        openai_output_items_to_service_charges(output_items.values)
      end

      def openai_stream_service_charges(events)
        output_items = {}
        each_event_data(events) do |data|
          Array(data.dig("response", "output")).each { |item| openai_store_output_item(output_items, item) }
          openai_store_output_item(output_items, data["item"])
        end
        openai_output_items_to_service_charges(output_items.values)
      end

      def openai_store_output_item(output_items, item)
        return unless item.is_a?(Hash)

        component = RESPONSE_OUTPUT_COMPONENTS[item["type"]]
        return unless component

        key = if component == :container_session && item["container_id"]
                "#{component}:#{item['container_id']}"
              else
                item["id"] || "#{item['type']}:#{output_items.length}"
              end
        output_items[key] = item
      end

      def openai_output_items_to_service_charges(output_items)
        output_items.filter_map do |item|
          component = RESPONSE_OUTPUT_COMPONENTS[item["type"]]
          next unless component

          provider_item_id = if component == :container_session
                               item["container_id"] || item["id"]
                             else
                               item["id"]
                             end
          Billing::ServiceCharge.build(
            component: component,
            quantity: 1,
            cost_status: Billing::CostStatus::UNKNOWN,
            pricing_basis: Billing::ServiceCharge::PROVIDER_USAGE_BASIS,
            source_key: "response.output.#{item['type']}",
            provider_item_id: provider_item_id,
            details: openai_service_charge_details(item)
          )
        end
      end

      def openai_service_charge_details(item)
        details = {}
        details["status"] = item["status"] if item["status"]
        details["action_type"] = item.dig("action", "type") if item.dig("action", "type")
        details["container_id"] = item["container_id"] if item["container_id"]
        details
      end
    end
  end
end
