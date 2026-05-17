# frozen_string_literal: true

require_relative "../billing/line_item"
require_relative "../providers/openai/model_families"

module LlmCostTracker
  module Parsers
    module OpenaiServiceCharges
      RESPONSE_OUTPUT_COMPONENTS = {
        "web_search_call" => :web_search_request,
        "file_search_call" => :file_search_call,
        "code_interpreter_call" => :container_session,
        "mcp_call" => :mcp_call
      }.freeze

      module_function

      def line_items_from_output(output_items, request: nil, model: nil)
        deduped = {}
        Array(output_items).each { |item| store_output_item(deduped, item) }
        deduped.values
               .select { |item| billable?(item) }
               .filter_map { |item| build_line_item(item, request: request, model: model) }
      end

      def service_line_items_for(response, request: nil, model: nil)
        output_items = Array(response["output"])
        output_items += chat_completions_web_search_items(response, model: model) if output_items.empty?
        line_items_from_output(output_items, request: request, model: model)
      end

      CHAT_COMPLETIONS_ANNOTATION_PROVIDER_FIELD = "choices.message.annotations.url_citation"
      CHAT_COMPLETIONS_SEARCH_MODEL_PROVIDER_FIELD = "request.model"

      def chat_completions_web_search_items(response, model: nil)
        return [] unless response["choices"]

        provider_field = chat_completions_search_provider_field(response["choices"], model)
        return [] unless provider_field

        [{ "type" => "web_search_call", "id" => response["id"], "action" => { "type" => "search" },
           "provider_field" => provider_field }]
      end

      def chat_completions_search_provider_field(choices, model)
        return CHAT_COMPLETIONS_ANNOTATION_PROVIDER_FIELD if chat_completions_used_web_search?(choices)
        return CHAT_COMPLETIONS_SEARCH_MODEL_PROVIDER_FIELD if chat_completions_search_model?(model)

        nil
      end

      def chat_completions_used_web_search?(choices)
        Array(choices).any? do |choice|
          Array(choice.dig("message", "annotations")).any? do |annotation|
            annotation.is_a?(Hash) && annotation["type"] == "url_citation"
          end
        end
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
        return unless item.is_a?(Hash) && RESPONSE_OUTPUT_COMPONENTS.key?(item["type"])

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
          provider_field: item["provider_field"] || "response.output.#{item['type']}",
          provider_item_id: provider_item_id,
          details: line_item_details(item)
        )
      end

      def component_key_for(item, request:, model:)
        component = RESPONSE_OUTPUT_COMPONENTS[item["type"]]
        return component unless component == :web_search_request
        return component unless web_search_preview_used?(request) || chat_completions_search_model?(model)

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

      def chat_completions_search_model?(model)
        return false unless model

        name = model.to_s.split("/", 2).last
        LlmCostTracker::Providers::Openai::ModelFamilies.chat_completions_search?(name)
      end

      def reasoning_model?(model)
        return false unless model

        name = model.to_s.split("/", 2).last
        LlmCostTracker::Providers::Openai::ModelFamilies.reasoning?(name)
      end

      def line_item_details(item)
        {
          "status" => item["status"],
          "action_type" => item.dig("action", "type"),
          "container_id" => item["container_id"]
        }.compact
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
