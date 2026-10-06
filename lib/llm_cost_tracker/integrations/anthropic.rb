# frozen_string_literal: true

require_relative "base"
require_relative "../providers/anthropic/response_parser"

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

        def record_message(message, request:, latency_ms:, host: nil)
          return unless active?

          record_safely do
            usage = message.usage
            next unless usage
            next if usage.input_tokens.nil? && usage.output_tokens.nil?

            usage_hash = usage.deep_to_h

            LlmCostTracker::Tracker.record(
              event: Providers::Anthropic::ResponseParser.event_from_usage(
                usage: usage_hash,
                model: message.model || request[:model],
                provider_response_id: message.id,
                usage_source: Usage::Source::SDK_RESPONSE,
                request: request,
                host: host,
                **response_fields(message)
              ),
              latency_ms: latency_ms
            )
          end
        end

        def record_batch_result(response)
          return unless active?

          record_safely do
            next unless response.respond_to?(:result) && response.result

            result = response.result
            next unless result.respond_to?(:type) && result.type.to_s == "succeeded"

            message = result.respond_to?(:message) ? result.message : nil
            next unless message
            next if LlmCostTracker::Call.already_recorded?(provider: "anthropic", provider_response_id: message.id)

            usage = message.usage
            next unless usage
            next if usage.input_tokens.nil? && usage.output_tokens.nil?

            record_once(
              Providers::Anthropic::ResponseParser.event_from_usage(
                usage: usage.deep_to_h.merge(service_tier: "batch"),
                model: message.model,
                provider_response_id: message.id,
                usage_source: Usage::Source::SDK_BATCH_RESULT,
                **response_fields(message)
              )
            )
          end
        end

        def record_refused_hop(request, response)
          record_safely { record_message(response.parse, request: request.body, latency_ms: nil) }
        rescue LlmCostTracker::BudgetExceededError, LlmCostTracker::UnknownPricingError
          nil
        end

        def record_refused_stream_hop(hop)
          return unless active?

          usage = hop.dig(:refused, :usage).to_h.deep_symbolize_keys
          output = usage[:output_tokens].to_i.positive?
          usage = usage.slice(:server_tool_use) if output
          return if output && Providers::Anthropic::UsageExtractor.service_line_items(usage).empty?

          record_safely do
            LlmCostTracker::Tracker.record(
              event: Providers::Anthropic::ResponseParser.event_from_usage(
                usage: usage,
                model: hop[:model],
                provider_response_id: nil,
                usage_source: Usage::Source::STREAM_FINAL,
                stream: true,
                stop_reason: ("refusal" unless output),
                refusal_category: hop.dig(:refused, :stop_details, "category")
              )
            )
          end
        rescue LlmCostTracker::BudgetExceededError, LlmCostTracker::UnknownPricingError
          nil
        end

        def stream_collector(request, host: nil)
          regional = Providers::Anthropic::UsageExtractor.regional_host?(host, request[:model])
          super(request, pricing_mode: ("data_residency" if regional))
        end

        def response_fields(message)
          { stop_reason: message.stop_reason, refusal_category: message.stop_details&.category,
            content: message.deep_to_h[:content] }
        end
      end

      module MessagesPatch
        def create(*args, **kwargs)
          host = LlmCostTracker::Integrations::Anthropic.client_host_for(self)
          LlmCostTracker::Integrations::Anthropic.wrap_blocking(
            args,
            kwargs,
            record: lambda do |message, request, latency_ms|
              LlmCostTracker::Integrations::Anthropic.record_message(
                message, request: request, latency_ms: latency_ms, host: host
              )
            end
          ) { super }
        end

        def stream(*args, **kwargs)
          host = LlmCostTracker::Integrations::Anthropic.client_host_for(self)
          LlmCostTracker::Integrations::Anthropic.wrap_stream(
            args,
            kwargs,
            collector: ->(request) { LlmCostTracker::Integrations::Anthropic.stream_collector(request, host: host) }
          ) { super }
        end

        def stream_raw(*args, **kwargs)
          host = LlmCostTracker::Integrations::Anthropic.client_host_for(self)
          LlmCostTracker::Integrations::Anthropic.wrap_stream(
            args,
            kwargs,
            collector: ->(request) { LlmCostTracker::Integrations::Anthropic.stream_collector(request, host: host) }
          ) { super }
        end
      end

      module FallbackMiddlewarePatch
        def call(req, nxt)
          return super if req.streaming? || !LlmCostTracker::Integrations::Anthropic.active?

          hops = []
          response = super(req, ->(hop_req) { nxt.call(hop_req).tap { |hop| hops << [hop_req, hop] } })
          answered = hops.select { |_hop_req, hop| hop.status < 300 }
          answered[...-1].each { |hop| LlmCostTracker::Integrations::Anthropic.record_refused_hop(*hop) }
          response
        end

        private

        def consume_hop(*args, **kwargs)
          refused = Thread.current[:llm_cost_tracker_refused_hop]
          Thread.current[:llm_cost_tracker_refused_hop] = nil
          LlmCostTracker::Integrations::Anthropic.record_refused_stream_hop(refused) if refused && kwargs[:splice]
          super.tap { |hop| Thread.current[:llm_cost_tracker_refused_hop] = hop if hop[:refused] }
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

          deferred = nil
          @raw_stream.each do |response|
            begin
              LlmCostTracker::Integrations::Anthropic.record_batch_result(response)
            rescue LlmCostTracker::BudgetExceededError, LlmCostTracker::UnknownPricingError => e
              deferred ||= e
            end
            block.call(response)
          end
          raise deferred if deferred
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
