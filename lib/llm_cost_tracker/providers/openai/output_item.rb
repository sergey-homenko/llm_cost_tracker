# frozen_string_literal: true

module LlmCostTracker
  module Providers
    module Openai
      class OutputItem
        RENAMED_TYPES = {
          "web_search_call" => "web_search_request",
          "code_interpreter_call" => "container_session"
        }.freeze

        attr_reader :dimension

        def self.wrap(data)
          item = new(data) if data.is_a?(Hash)
          item if item&.dimension
        end

        def initialize(data)
          @data = data
          @dimension = shell_session? ? "container_session" : catalog_dimension
        end

        def billable?
          case dimension
          when "image_generation_call" then @data["status"] == "completed"
          when "web_search_request" then [nil, "search"].include?(@data.dig("action", "type"))
          else true
          end
        end

        def dedup_key(position)
          return "#{dimension}:#{container_id}" if dimension == "container_session" && container_id

          @data["id"] || "#{@data['type']}:#{position}"
        end

        def line_item(dimension_key)
          Charges::LineItem.build(
            dimension_key: dimension_key,
            quantity: 1,
            cost_status: Charges::CostStatus::UNKNOWN,
            pricing_basis: "provider_usage",
            provider_field: @data["provider_field"] || "response.output.#{@data['type']}",
            provider_item_id: dimension_key == "container_session" ? container_id || @data["id"] : @data["id"],
            details: details
          )
        end

        def billing_fields
          @data.slice("type", "id", "status", "container_id").merge(
            "action" => @data["action"]&.slice("type"),
            "environment" => @data["environment"]&.slice("type", "container_id")
          ).compact
        end

        private

        def shell_session?
          @data["type"] == "shell_call" && shell_container_id
        end

        def catalog_dimension
          key = RENAMED_TYPES[@data["type"]] || @data["type"]
          dimension = Usage::Catalog[key]
          key if dimension && dimension.token_key.nil?
        end

        def container_id
          @data["container_id"] || shell_container_id
        end

        def shell_container_id
          environment = @data["environment"]
          environment["container_id"] if environment.is_a?(Hash) && environment["type"] == "container_reference"
        end

        def details
          { status: @data["status"], action_type: @data.dig("action", "type"), container_id: container_id }.compact
        end
      end
    end
  end
end
