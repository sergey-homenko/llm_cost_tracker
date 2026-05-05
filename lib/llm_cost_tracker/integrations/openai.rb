# frozen_string_literal: true

require_relative "base"
require_relative "../capture/stream_collector"
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
                pricing_mode: object_value(response, :service_tier) || request[:service_tier],
                token_usage: token_usage(usage:, input_tokens:, output_tokens:, cache_read:),
                usage_source: :sdk_response,
                provider_response_id: object_value(response, :id)
              ),
              latency_ms: latency_ms
            )
          end
        end

        def token_usage(usage:, input_tokens:, output_tokens:, cache_read:)
          audio_input = audio_input_tokens(usage)
          audio_output = audio_output_tokens(usage)

          TokenUsage.build(
            input_tokens: regular_input_tokens(input_tokens, cache_read, audio_input),
            output_tokens: regular_output_tokens(output_tokens, audio_output),
            cache_read_input_tokens: cache_read,
            audio_input_tokens: audio_input,
            audio_output_tokens: audio_output,
            hidden_output_tokens: hidden_output_tokens(usage)
          )
        end

        INPUT_DETAIL_KEYS = %i[input_tokens_details input_token_details prompt_tokens_details].freeze
        OUTPUT_DETAIL_KEYS = %i[output_tokens_details output_token_details completion_tokens_details].freeze

        def cache_read_input_tokens(usage)
          input_detail(usage, :cached_tokens)
        end

        def hidden_output_tokens(usage)
          output_detail(usage, :reasoning_tokens)
        end

        def audio_input_tokens(usage)
          input_detail(usage, :audio_tokens)
        end

        def audio_output_tokens(usage)
          output_detail(usage, :audio_tokens)
        end

        def input_detail(usage, key)
          INPUT_DETAIL_KEYS.each do |container|
            value = object_dig(usage, container, key)
            return value.to_i if value
          end
          0
        end

        def output_detail(usage, key)
          OUTPUT_DETAIL_KEYS.each do |container|
            value = object_dig(usage, container, key)
            return value.to_i if value
          end
          0
        end

        def regular_input_tokens(input_tokens, cache_read, audio_input)
          [input_tokens.to_i - cache_read - audio_input, 0].max
        end

        def regular_output_tokens(output_tokens, audio_output)
          [output_tokens.to_i - audio_output, 0].max
        end

        def track_stream(stream, collector:)
          return stream unless active?

          LlmCostTracker::Capture::StreamTracker.new(
            stream: stream,
            collector: collector,
            active: -> { active? },
            finish: ->(errored:) { finish_stream(collector, errored: errored) }
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
          LlmCostTracker::Integrations::Openai.enforce_budget!
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
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
          LlmCostTracker::Integrations::Openai.enforce_budget!
          collector = LlmCostTracker::Integrations::Openai.stream_collector(request)
          stream = super
          LlmCostTracker::Integrations::Openai.track_stream(stream, collector: collector)
        end

        def stream_raw(*args, **kwargs)
          request = LlmCostTracker::Integrations::Openai.request_params(args, kwargs)
          LlmCostTracker::Integrations::Openai.enforce_budget!
          collector = LlmCostTracker::Integrations::Openai.stream_collector(request)
          stream = super
          LlmCostTracker::Integrations::Openai.track_stream(stream, collector: collector)
        end

        def retrieve_streaming(response_id, *args, **kwargs)
          request = LlmCostTracker::Integrations::Openai.request_params(args, kwargs)
          LlmCostTracker::Integrations::Openai.enforce_budget!
          collector = LlmCostTracker::Integrations::Openai.stream_collector(request)
          collector.provider_response_id = response_id
          stream = super
          LlmCostTracker::Integrations::Openai.track_stream(stream, collector: collector)
        end
      end

      module ChatCompletionsPatch
        def create(*args, **kwargs)
          LlmCostTracker::Integrations::Openai.enforce_budget!
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
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
          LlmCostTracker::Integrations::Openai.enforce_budget!
          collector = LlmCostTracker::Integrations::Openai.stream_collector(request)
          stream = super
          LlmCostTracker::Integrations::Openai.track_stream(stream, collector: collector)
        end
      end
    end
  end
end
