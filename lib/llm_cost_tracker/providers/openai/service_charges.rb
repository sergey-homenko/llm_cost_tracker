# frozen_string_literal: true

require_relative "model_families"
require_relative "output_item"

module LlmCostTracker
  module Providers
    module Openai
      module ServiceCharges
        TICKS_PER_USD = 10_000_000_000

        class << self
          def service_line_items_for(response, request: nil, model: nil)
            output_items = Array(response["output"])
            output_items += chat_completions_web_search_items(response, model: model) if output_items.empty?
            line_items_from_output(output_items, request: request, model: model)
          end

          def line_items_from_output(output_items, request: nil, model: nil)
            unique = {}
            Array(output_items).each do |data|
              item = OutputItem.wrap(data)
              unique[item.dedup_key(unique.length)] = item if item
            end
            unique.values.select(&:billable?).map { |item| priced_line_item(item, request: request, model: model) }
          end

          def billable?(item)
            OutputItem.wrap(item)&.billable? || false
          end

          def build_line_item(item, request: nil, model: nil)
            output_item = OutputItem.wrap(item)
            priced_line_item(output_item, request: request, model: model) if output_item
          end

          def billing_fields(item)
            OutputItem.wrap(item)&.billing_fields
          end

          def transcription_line_items(usage)
            return [] unless usage

            field = (usage[:type] || usage["type"]).to_s == "duration" ? "seconds" : "prompt_audio_seconds"
            seconds = (usage[field.to_sym] || usage[field]).to_f
            return [] unless seconds.positive?

            [Charges::LineItem.build(
              dimension_key: "transcription_minute",
              quantity: BigDecimal(seconds.to_s) / 60,
              cost_status: Charges::CostStatus::UNKNOWN,
              pricing_basis: "provider_usage",
              provider_field: "usage.#{field}",
              details: { seconds: seconds }
            )]
          end

          def speech_line_items(request)
            input = request["input"]
            return [] unless input.is_a?(String) && ModelFamilies.character_billed_tts?(request["model"])

            [Charges::LineItem.build(
              dimension_key: "text_to_speech_character",
              quantity: input.length,
              cost_status: Charges::CostStatus::UNKNOWN,
              pricing_basis: "provider_usage",
              provider_field: "request.input"
            )]
          end

          def ocr_line_items(response)
            pages = response.dig("usage_info", "pages_processed")
            return unit_line_items("ocr_page", pages, "usage_info.pages_processed") if pages

            unit_line_items("ocr_page", response.dig("meta", "billed_units", "pages"), "meta.billed_units.pages")
          end

          def rerank_line_items(response)
            units = response.dig("meta", "billed_units", "search_units")
            unit_line_items("rerank_search_unit", units, "meta.billed_units.search_units")
          end

          def billed_line_items(usage)
            amount, field = billed_amount(usage)
            return [] unless amount

            [Charges::LineItem.build(
              dimension_key: "billed_request",
              quantity: 1,
              rate_amount: amount,
              cost: amount,
              pricing_basis: "provider_usage",
              price_source: "provider_response",
              provider_field: field
            )]
          end

          private

          def chat_completions_web_search_items(response, model: nil)
            return [] unless response["choices"] && chat_completions_search_model?(model)

            [{ "type" => "web_search_call", "id" => response["id"], "action" => { "type" => "search" },
               "provider_field" => "request.model" }]
          end

          def priced_line_item(item, request:, model:)
            item.line_item(priced_dimension(item.dimension, request: request, model: model))
          end

          def priced_dimension(dimension, request:, model:)
            return dimension unless dimension == "web_search_request"
            return dimension unless web_search_preview_used?(request) || chat_completions_search_model?(model)
            return "web_search_preview_request_reasoning" if reasoning_model?(model)

            "web_search_preview_request_non_reasoning"
          end

          def web_search_preview_used?(request)
            tools = request && (request[:tools] || request["tools"])
            Array(tools).any? do |tool|
              type = tool.is_a?(Hash) ? (tool[:type] || tool["type"]) : tool
              type.to_s.include?("web_search_preview")
            end
          end

          def chat_completions_search_model?(model)
            name = local_model_name(model)
            name && ModelFamilies.chat_completions_search?(name)
          end

          def reasoning_model?(model)
            name = local_model_name(model)
            name && ModelFamilies.reasoning?(name)
          end

          def local_model_name(model)
            return nil unless model

            model.to_s.split("/", 2).last
          end

          def unit_line_items(dimension_key, quantity, provider_field)
            return [] unless quantity.is_a?(Numeric) && quantity.positive?

            [Charges::LineItem.build(
              dimension_key: dimension_key,
              quantity: quantity,
              cost_status: Charges::CostStatus::UNKNOWN,
              pricing_basis: "provider_usage",
              provider_field: provider_field
            )]
          end

          def billed_amount(usage)
            cost = usage[:cost]
            return reported_cost(usage, cost) if cost.is_a?(Numeric)

            ticks = usage[:cost_in_usd_ticks]
            return [BigDecimal(ticks.to_s) / TICKS_PER_USD, "usage.cost_in_usd_ticks"] if ticks.is_a?(Numeric)

            total = cost[:total_cost] if cost.is_a?(Hash)
            [BigDecimal(total.to_s), "usage.cost.total_cost"] if total.is_a?(Numeric) && total.positive?
          end

          def reported_cost(usage, cost)
            amounts = [cost]
            amounts << usage.dig(:cost_details, :upstream_inference_cost) if usage[:is_byok]
            [amounts.sum { |value| BigDecimal(value.to_s) }, "usage.cost"] if amounts.all?(Numeric)
          end
        end
      end
    end
  end
end
