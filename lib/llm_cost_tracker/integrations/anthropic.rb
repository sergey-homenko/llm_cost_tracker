# frozen_string_literal: true

require_relative "base"
require_relative "../providers/anthropic/response_parser"
require_relative "anthropic/patches"
require_relative "anthropic/batch_results_capture"

module LlmCostTracker
  module Integrations
    module Anthropic
      extend Base

      minimum_version "1.36.0"

      class << self
        def patch_targets
          [
            patch_target("Anthropic::Resources::Messages", with: MessagesPatch),
            patch_target("Anthropic::Resources::Beta::Messages", with: MessagesPatch, optional: true),
            patch_target("Anthropic::Resources::Messages::Batches", with: BatchesPatch, optional: true),
            patch_target("Anthropic::Resources::Beta::Messages::Batches", with: BatchesPatch, optional: true),
            patch_target("Anthropic::BetaRefusalFallbackMiddleware", with: FallbackMiddlewarePatch, optional: true)
          ]
        end

        def blocking_seam(client)
          host = client_host(client)
          {
            record: lambda do |message, request, latency_ms|
              record_message(message, request: request, latency_ms: latency_ms, host: host)
            end
          }
        end

        def stream_seam(client)
          host = client_host(client)
          { collector: ->(request) { stream_collector(request, host: host) } }
        end

        def stream_collector(request, host: nil)
          regional = Providers::Anthropic::UsageExtractor.regional_host?(host, request[:model])
          super(request, pricing_mode: ("data_residency" if regional))
        end

        def record_message(message, request:, latency_ms:, host: nil)
          return unless active?

          record_safely do
            usage = message.usage
            next unless tokens_reported?(usage)

            Tracker.record(
              event: message_event(
                message,
                usage: usage.deep_to_h,
                model: message.model || request[:model],
                usage_source: Usage::Source::SDK_RESPONSE,
                request: request,
                host: host
              ),
              latency_ms: latency_ms
            )
          end
        end

        def record_batch_result(response)
          return unless active?

          record_safely do
            message = succeeded_message(response)
            next unless message
            next if Call.already_recorded?(provider: "anthropic", provider_response_id: message.id)

            usage = message.usage
            next unless tokens_reported?(usage)

            record_once(
              message_event(
                message,
                usage: usage.deep_to_h.merge(service_tier: "batch"),
                model: message.model,
                usage_source: Usage::Source::SDK_BATCH_RESULT
              )
            )
          end
        end

        def record_refused_hop(request, response)
          record_safely { record_message(response.parse, request: request.body, latency_ms: nil) }
        rescue BudgetExceededError, UnknownPricingError
          nil
        end

        def record_refused_stream_hop(hop)
          return unless active?

          usage = hop.dig(:refused, :usage).to_h.deep_symbolize_keys
          produced_output = usage[:output_tokens].to_i.positive?
          usage = usage.slice(:server_tool_use) if produced_output
          return if produced_output && Providers::Anthropic::UsageExtractor.service_line_items(usage).empty?

          record_safely do
            Tracker.record(
              event: Providers::Anthropic::ResponseParser.event_from_usage(
                usage: usage,
                model: hop[:model],
                provider_response_id: nil,
                usage_source: Usage::Source::STREAM_FINAL,
                stream: true,
                stop_reason: ("refusal" unless produced_output),
                refusal_category: hop.dig(:refused, :stop_details, "category")
              )
            )
          end
        rescue BudgetExceededError, UnknownPricingError
          nil
        end

        private

        def succeeded_message(response)
          result = response.result if response.respond_to?(:result)
          return unless result.respond_to?(:type) && result.type.to_s == "succeeded"

          result.message if result.respond_to?(:message)
        end

        def tokens_reported?(usage)
          usage && !(usage.input_tokens.nil? && usage.output_tokens.nil?)
        end

        def message_event(message, **attributes)
          Providers::Anthropic::ResponseParser.event_from_usage(
            provider_response_id: message.id,
            stop_reason: message.stop_reason,
            refusal_category: message.stop_details&.category,
            content: message.deep_to_h[:content],
            **attributes
          )
        end
      end
    end
  end
end
