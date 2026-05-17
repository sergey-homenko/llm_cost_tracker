# frozen_string_literal: true

require_relative "base"
require_relative "../billing/line_item"
require_relative "../providers/anthropic/tier_classification"

module LlmCostTracker
  module Integrations
    module Anthropic
      extend Base

      class << self
        def integration_name
          :anthropic
        end

        def minimum_version
          "1.36.0"
        end

        def version_constant
          "Anthropic::VERSION"
        end

        def patch_targets
          [
            patch_target("Anthropic::Resources::Messages", with: MessagesPatch, methods: %i[create stream stream_raw]),
            patch_target(
              "Anthropic::Resources::Beta::Messages",
              with: MessagesPatch,
              methods: %i[create stream stream_raw],
              optional: true
            )
          ]
        end

        def record_message(message, request:, latency_ms:)
          return unless active?

          record_safely do
            usage = object_value(message, :usage)
            next unless usage

            input_tokens = object_value(usage, :input_tokens)
            output_tokens = object_value(usage, :output_tokens)
            next if input_tokens.nil? && output_tokens.nil?

            LlmCostTracker::Tracker.record(
              event: Event.build(
                provider: "anthropic",
                model: object_value(message, :model) || request[:model],
                pricing_mode: pricing_mode(request: request, usage: usage),
                token_usage: token_usage(usage: usage, input_tokens: input_tokens, output_tokens: output_tokens),
                usage_source: :sdk_response,
                provider_response_id: object_value(message, :id),
                service_line_items: service_line_items_from(usage)
              ),
              latency_ms: latency_ms
            )
          end
        end

        def service_line_items_from(usage)
          server_tool_use = object_value(usage, :server_tool_use)
          return [] unless server_tool_use

          [
            line_item_for_server_tool(server_tool_use, :web_search_request, :web_search_requests,
                                      "usage.server_tool_use.web_search_requests"),
            line_item_for_server_tool(server_tool_use, :web_fetch_request, :web_fetch_requests,
                                      "usage.server_tool_use.web_fetch_requests"),
            line_item_for_server_tool(server_tool_use, :code_execution_request, :code_execution_requests,
                                      "usage.server_tool_use.code_execution_requests")
          ].compact
        end

        def line_item_for_server_tool(server_tool_use, component_key, count_key, provider_field)
          quantity = object_value(server_tool_use, count_key).to_i
          return nil if quantity.zero?

          Billing::LineItem.build(
            component_key: component_key,
            quantity: quantity,
            cost_status: Billing::CostStatus::UNKNOWN,
            pricing_basis: :provider_usage,
            provider_field: provider_field
          )
        end

        def token_usage(usage:, input_tokens:, output_tokens:)
          cache_creation = object_value(usage, :cache_creation)
          if cache_creation
            cache_write_default = object_value(cache_creation, :ephemeral_5m_input_tokens).to_i
            cache_write_extended = object_value(cache_creation, :ephemeral_1h_input_tokens).to_i
          else
            cache_write_default = object_value(usage, :cache_creation_input_tokens).to_i
            cache_write_extended = 0
          end
          hidden_output = (
            object_value(usage, :thinking_tokens, :thinking_output_tokens) ||
            object_dig(usage, :output_tokens_details, :reasoning_tokens)
          ).to_i

          TokenUsage.build(
            input_tokens: input_tokens.to_i,
            output_tokens: output_tokens.to_i,
            cache_read_input_tokens: object_value(usage, :cache_read_input_tokens).to_i,
            cache_write_input_tokens: cache_write_default,
            cache_write_extended_input_tokens: cache_write_extended,
            hidden_output_tokens: hidden_output
          )
        end

        def pricing_mode(request:, usage:)
          service_tier = object_value(usage, :service_tier) || request[:service_tier]
          tier = Providers::Anthropic::TierClassification
          service_tier = nil if tier.standard_equivalent_tier?(service_tier)

          modes = [
            Pricing.normalize_mode(object_value(usage, :speed) || request[:speed]),
            Pricing.normalize_mode(service_tier)
          ]
          geo = inference_geo(request: request, usage: usage).to_s.downcase
          modes << "data_residency" if tier.data_residency_geo?(geo)
          modes = modes.compact.uniq
          modes.empty? ? nil : modes.join("_")
        end

        def stream_pricing_mode(request)
          pricing_mode(request: request || {}, usage: nil)
        end

        def inference_geo(request:, usage:)
          object_value(usage, :inference_geo) || request[:inference_geo]
        end

        def wrap_stream_call(args, kwargs)
          request = request_params(args, kwargs)
          enforce_budget!(request: request)
          collector = stream_collector(request)
          stream = yield
          track_stream(stream, collector: collector)
        end
      end

      module MessagesPatch
        def create(*args, **kwargs)
          request = LlmCostTracker::Integrations::Anthropic.request_params(args, kwargs)
          LlmCostTracker::Integrations::Anthropic.enforce_budget!(request: request)
          started_at = LlmCostTracker::Timing.now_monotonic
          message = super
          LlmCostTracker::Integrations::Anthropic.record_message(
            message,
            request: request,
            latency_ms: LlmCostTracker::Timing.elapsed_ms(started_at)
          )
          message
        end

        def stream(*args, **kwargs)
          LlmCostTracker::Integrations::Anthropic.wrap_stream_call(args, kwargs) { super }
        end

        def stream_raw(*args, **kwargs)
          LlmCostTracker::Integrations::Anthropic.wrap_stream_call(args, kwargs) { super }
        end
      end
    end
  end
end
