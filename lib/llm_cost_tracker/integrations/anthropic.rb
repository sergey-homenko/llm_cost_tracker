# frozen_string_literal: true

require_relative "base"
require_relative "../providers/anthropic/usage_extractor"

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
                usage_source: Usage::Source::SDK_RESPONSE,
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
          return if LlmCostTracker::Call.already_recorded?(provider: "anthropic", provider_response_id: message.id)

          record_safely do
            usage = message.usage
            next unless usage
            next if usage.input_tokens.nil? && usage.output_tokens.nil?

            usage_hash = usage.deep_to_h
            LlmCostTracker::Tracker.record(
              event: Event.build(
                provider: "anthropic",
                model: message.model,
                pricing_mode: "batch",
                token_usage: Providers::Anthropic::UsageExtractor.token_usage(usage_hash),
                usage_source: Usage::Source::SDK_BATCH_RESULT,
                provider_response_id: message.id,
                service_line_items: Providers::Anthropic::UsageExtractor.service_line_items(usage_hash)
              )
            )
          end
        end

        def stream_pricing_mode(request)
          Providers::Anthropic::UsageExtractor.pricing_mode(request: request || {}, usage: nil)
        end
      end

      module MessagesPatch
        def create(*args, **kwargs)
          LlmCostTracker::Integrations::Anthropic.wrap_blocking(
            args,
            kwargs,
            record: lambda do |message, request, latency_ms|
              LlmCostTracker::Integrations::Anthropic.record_message(
                message, request: request, latency_ms: latency_ms
              )
            end
          ) { super }
        end

        def stream(*args, **kwargs)
          LlmCostTracker::Integrations::Anthropic.wrap_stream(
            args,
            kwargs,
            collector: ->(request) { LlmCostTracker::Integrations::Anthropic.stream_collector(request) }
          ) { super }
        end

        def stream_raw(*args, **kwargs)
          LlmCostTracker::Integrations::Anthropic.wrap_stream(
            args,
            kwargs,
            collector: ->(request) { LlmCostTracker::Integrations::Anthropic.stream_collector(request) }
          ) { super }
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
