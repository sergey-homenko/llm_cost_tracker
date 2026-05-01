# frozen_string_literal: true

require_relative "base"
require_relative "../capture/stream_collector"
require_relative "../capture/stream_tracker"

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
              capture: UsageCapture.build(
                provider: "anthropic",
                model: object_value(message, :model) || request[:model],
                pricing_mode: pricing_mode(message, request, usage),
                token_usage: token_usage(usage, input_tokens, output_tokens),
                usage_source: :sdk_response,
                provider_response_id: object_value(message, :id)
              ),
              latency_ms: latency_ms
            )
          end
        end

        def token_usage(usage, input_tokens, output_tokens)
          cache_write_1h = object_dig(usage, :cache_creation, :ephemeral_1h_input_tokens).to_i
          cache_write_5m = object_dig(usage, :cache_creation, :ephemeral_5m_input_tokens)
          cache_write = if cache_write_5m.nil?
                          total_cache_write = object_value(usage, :cache_creation_input_tokens)
                          [total_cache_write.to_i - cache_write_1h, 0].max
                        else
                          cache_write_5m.to_i
                        end
          hidden_output = (
            object_value(usage, :thinking_tokens, :thinking_output_tokens) ||
            object_dig(usage, :output_tokens_details, :reasoning_tokens)
          ).to_i

          TokenUsage.build(
            input_tokens: input_tokens.to_i,
            output_tokens: output_tokens.to_i,
            cache_read_input_tokens: object_value(usage, :cache_read_input_tokens).to_i,
            cache_write_input_tokens: cache_write,
            cache_write_1h_input_tokens: cache_write_1h,
            hidden_output_tokens: hidden_output
          )
        end

        def pricing_mode(message, request, usage)
          modes = [
            Pricing.normalize_mode(object_value(usage, :speed) || object_value(message, :speed) || request[:speed]),
            Pricing.normalize_mode(
              object_value(usage, :service_tier) || object_value(message, :service_tier) || request[:service_tier]
            )
          ]
          modes << "data_residency" if inference_geo(message, request, usage).to_s == "us"
          modes = modes.compact.uniq
          modes.empty? ? nil : modes.join("_")
        end

        def inference_geo(message, request, usage)
          object_value(usage, :inference_geo) ||
            object_value(message, :inference_geo) ||
            request[:inference_geo]
        end

        def track_stream(stream, collector:)
          return stream unless active?

          LlmCostTracker::Capture::StreamTracker.new(
            stream,
            collector,
            -> { active? },
            ->(errored:) { finish_stream(collector, errored: errored) }
          ).wrap
        end

        def stream_collector(request)
          LlmCostTracker::Capture::StreamCollector.new(
            provider: "anthropic",
            model: request[:model]
          )
        end

        def finish_stream(collector, errored:)
          record_safely { collector.finish!(errored: errored) }
        end
      end

      module MessagesPatch
        def create(*args, **kwargs)
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          LlmCostTracker::Integrations::Anthropic.enforce_budget!
          message = super
          LlmCostTracker::Integrations::Anthropic.record_message(
            message,
            request: LlmCostTracker::Integrations::Anthropic.request_params(args, kwargs),
            latency_ms: LlmCostTracker::Integrations::Anthropic.elapsed_ms(started_at)
          )
          message
        end

        def stream(*args, **kwargs)
          request = LlmCostTracker::Integrations::Anthropic.request_params(args, kwargs)
          collector = LlmCostTracker::Integrations::Anthropic.stream_collector(request)
          LlmCostTracker::Integrations::Anthropic.enforce_budget!
          stream = super
          LlmCostTracker::Integrations::Anthropic.track_stream(stream, collector: collector)
        end

        def stream_raw(*args, **kwargs)
          request = LlmCostTracker::Integrations::Anthropic.request_params(args, kwargs)
          collector = LlmCostTracker::Integrations::Anthropic.stream_collector(request)
          LlmCostTracker::Integrations::Anthropic.enforce_budget!
          stream = super
          LlmCostTracker::Integrations::Anthropic.track_stream(stream, collector: collector)
        end
      end
    end
  end
end
