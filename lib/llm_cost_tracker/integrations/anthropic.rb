# frozen_string_literal: true

require_relative "base"
require_relative "../providers/anthropic/usage_extractor"

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
            patch_target("Anthropic::Resources::Messages", with: MessagesPatch),
            patch_target("Anthropic::Resources::Beta::Messages", with: MessagesPatch, optional: true),
            patch_target("Anthropic::Resources::Messages::Batches", with: BatchesPatch, optional: true),
            patch_target("Anthropic::Resources::Beta::Messages::Batches", with: BatchesPatch, optional: true)
          ]
        end

        def record_message(message, request:, latency_ms:)
          return unless active?

          record_safely do
            usage = message.usage
            next unless usage
            next if usage.input_tokens.nil? && usage.output_tokens.nil?

            usage_hash = usage.deep_to_h

            LlmCostTracker::Tracker.record(
              event: Event.build(
                provider: "anthropic",
                model: message.model || request[:model],
                pricing_mode: Providers::Anthropic::UsageExtractor.pricing_mode(request: request, usage: usage_hash),
                token_usage: Providers::Anthropic::UsageExtractor.token_usage(usage_hash),
                usage_source: "sdk_response",
                provider_response_id: message.id,
                service_line_items: Providers::Anthropic::UsageExtractor.service_line_items(usage_hash)
              ),
              latency_ms: latency_ms
            )
          end
        end

        def record_batch_result(response)
          return unless active?
          return unless response.respond_to?(:result) && response.result

          result = response.result
          return unless result.respond_to?(:type) && result.type.to_s == "succeeded"

          message = result.respond_to?(:message) ? result.message : nil
          return unless message

          record_safely do
            usage = message.usage
            next unless usage
            next if usage.input_tokens.nil? && usage.output_tokens.nil?

            usage_hash = usage.deep_to_h
            LlmCostTracker::Tracker.record(
              event: Event.build(
                provider: "anthropic",
                model: message.model,
                pricing_mode: :batch,
                token_usage: Providers::Anthropic::UsageExtractor.token_usage(usage_hash),
                usage_source: "sdk_batch_result",
                provider_response_id: message.id,
                service_line_items: Providers::Anthropic::UsageExtractor.service_line_items(usage_hash)
              )
            )
          end
        end

        def stream_pricing_mode(request)
          Providers::Anthropic::UsageExtractor.pricing_mode(request: request || {}, usage: nil)
        end

        def wrap_stream_call(args, kwargs)
          request = request_params(args, kwargs)
          enforce_budget!(request: request)
          collector = stream_collector(request)
          stream = yield
          track_stream(stream, collector: collector)
        end

        def wrap_blocking_call(args, kwargs)
          request = request_params(args, kwargs)
          enforce_budget!(request: request)
          started_at = LlmCostTracker::Timing.now_monotonic
          message = yield
          record_message(message, request: request, latency_ms: LlmCostTracker::Timing.elapsed_ms(started_at))
          message
        end
      end

      module MessagesPatch
        def create(*args, **kwargs)
          LlmCostTracker::Integrations::Anthropic.wrap_blocking_call(args, kwargs) { super }
        end

        def stream(*args, **kwargs)
          LlmCostTracker::Integrations::Anthropic.wrap_stream_call(args, kwargs) { super }
        end

        def stream_raw(*args, **kwargs)
          LlmCostTracker::Integrations::Anthropic.wrap_stream_call(args, kwargs) { super }
        end
      end

      module BatchesPatch
        def results_streaming(*args, **kwargs)
          raw = super
          return raw unless LlmCostTracker::Integrations::Anthropic.active?

          BatchResultsCapture.new(raw)
        end
      end

      class BatchResultsCapture
        include Enumerable

        def initialize(raw_stream)
          @raw_stream = raw_stream
        end

        def each(&block)
          return enum_for(:each) unless block

          @raw_stream.each do |response|
            LlmCostTracker::Integrations::Anthropic.record_batch_result(response)
            block.call(response)
          end
        end

        def respond_to_missing?(name, include_private = false)
          @raw_stream.respond_to?(name, include_private) || super
        end

        def method_missing(name, ...)
          return super unless @raw_stream.respond_to?(name)

          @raw_stream.public_send(name, ...)
        end
      end
    end
  end
end
