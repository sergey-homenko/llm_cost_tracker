# frozen_string_literal: true

require_relative "base"
require_relative "../capture/stream_tracker"

module LlmCostTracker
  module Integrations
    module Openai
      extend Base

      class << self
        def integration_name
          :openai
        end

        def minimum_version
          "0.59.0"
        end

        def version_constant
          "OpenAI::VERSION"
        end

        def patch_targets
          [
            patch_target(
              "OpenAI::Resources::Responses",
              with: ResponsesPatch,
              methods: %i[create stream stream_raw retrieve_streaming]
            ),
            patch_target(
              "OpenAI::Resources::Chat::Completions",
              with: ChatCompletionsPatch,
              methods: %i[create stream_raw]
            )
          ]
        end

        def record_response(response, request:, latency_ms:)
          return unless active?

          record_safely do
            usage = object_value(response, :usage)
            next unless usage

            input_tokens = object_value(usage, :input_tokens, :prompt_tokens)
            output_tokens = object_value(usage, :output_tokens, :completion_tokens)
            next if input_tokens.nil? && output_tokens.nil?

            cache_read = cache_read_input_tokens(usage)
            LlmCostTracker::Tracker.record(
              capture: UsageCapture.build(
                provider: "openai",
                model: object_value(response, :model) || request[:model],
                token_usage: TokenUsage.build(
                  input_tokens: regular_input_tokens(input_tokens, cache_read),
                  output_tokens: output_tokens.to_i,
                  cache_read_input_tokens: cache_read,
                  hidden_output_tokens: hidden_output_tokens(usage)
                ),
                usage_source: :sdk_response,
                provider_response_id: object_value(response, :id)
              ),
              latency_ms: latency_ms
            )
          end
        end

        def cache_read_input_tokens(usage)
          (
            object_dig(usage, :input_tokens_details, :cached_tokens) ||
            object_dig(usage, :prompt_tokens_details, :cached_tokens)
          ).to_i
        end

        def hidden_output_tokens(usage)
          (
            object_dig(usage, :output_tokens_details, :reasoning_tokens) ||
            object_dig(usage, :completion_tokens_details, :reasoning_tokens)
          ).to_i
        end

        def regular_input_tokens(input_tokens, cache_read)
          [input_tokens.to_i - cache_read.to_i, 0].max
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
            provider: "openai",
            model: request[:model]
          )
        end

        def finish_stream(collector, errored:)
          record_safely { collector.finish!(errored: errored) }
        end
      end

      module ResponsesPatch
        def create(*args, **kwargs)
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          LlmCostTracker::Integrations::Openai.enforce_budget!
          response = super
          LlmCostTracker::Integrations::Openai.record_response(
            response,
            request: LlmCostTracker::Integrations::Openai.request_params(args, kwargs),
            latency_ms: LlmCostTracker::Integrations::Openai.elapsed_ms(started_at)
          )
          response
        end

        def stream(*args, **kwargs)
          request = LlmCostTracker::Integrations::Openai.request_params(args, kwargs)
          collector = LlmCostTracker::Integrations::Openai.stream_collector(request)
          LlmCostTracker::Integrations::Openai.enforce_budget!
          stream = super
          LlmCostTracker::Integrations::Openai.track_stream(stream, collector: collector)
        end

        def stream_raw(*args, **kwargs)
          request = LlmCostTracker::Integrations::Openai.request_params(args, kwargs)
          collector = LlmCostTracker::Integrations::Openai.stream_collector(request)
          LlmCostTracker::Integrations::Openai.enforce_budget!
          stream = super
          LlmCostTracker::Integrations::Openai.track_stream(stream, collector: collector)
        end

        def retrieve_streaming(response_id, *args, **kwargs)
          request = LlmCostTracker::Integrations::Openai.request_params(args, kwargs)
          collector = LlmCostTracker::Integrations::Openai.stream_collector(request)
          collector.provider_response_id = response_id
          LlmCostTracker::Integrations::Openai.enforce_budget!
          stream = super
          LlmCostTracker::Integrations::Openai.track_stream(stream, collector: collector)
        end
      end

      module ChatCompletionsPatch
        def create(*args, **kwargs)
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          LlmCostTracker::Integrations::Openai.enforce_budget!
          response = super
          LlmCostTracker::Integrations::Openai.record_response(
            response,
            request: LlmCostTracker::Integrations::Openai.request_params(args, kwargs),
            latency_ms: LlmCostTracker::Integrations::Openai.elapsed_ms(started_at)
          )
          response
        end

        def stream_raw(*args, **kwargs)
          request = LlmCostTracker::Integrations::Openai.request_params(args, kwargs)
          collector = LlmCostTracker::Integrations::Openai.stream_collector(request)
          LlmCostTracker::Integrations::Openai.enforce_budget!
          stream = super
          LlmCostTracker::Integrations::Openai.track_stream(stream, collector: collector)
        end
      end
    end
  end
end
