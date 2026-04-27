# frozen_string_literal: true

require_relative "base"

module LlmCostTracker
  module Integrations
    module Openai
      extend Base

      class << self
        def integration_name = :openai

        def target_patches
          [
            [constant("OpenAI::Resources::Responses"), ResponsesPatch],
            [constant("OpenAI::Resources::Chat::Completions"), ChatCompletionsPatch]
          ]
        end

        def record_response(response, request:, latency_ms:)
          return unless active?

          record_safely do
            usage = ObjectReader.first(response, :usage)
            next unless usage

            input_tokens = ObjectReader.first(usage, :input_tokens, :prompt_tokens)
            output_tokens = ObjectReader.first(usage, :output_tokens, :completion_tokens)
            next if input_tokens.nil? && output_tokens.nil?

            metadata = usage_metadata(usage)
            LlmCostTracker::Tracker.record(
              provider: "openai",
              model: ObjectReader.first(response, :model) || request[:model],
              input_tokens: regular_input_tokens(input_tokens, metadata[:cache_read_input_tokens]),
              output_tokens: ObjectReader.integer(output_tokens),
              latency_ms: latency_ms,
              usage_source: :sdk_response,
              provider_response_id: ObjectReader.first(response, :id),
              metadata: metadata
            )
          end
        end

        def usage_metadata(usage)
          {
            cache_read_input_tokens: cache_read_input_tokens(usage),
            hidden_output_tokens: hidden_output_tokens(usage)
          }
        end

        def cache_read_input_tokens(usage)
          ObjectReader.integer(
            ObjectReader.nested(usage, :input_tokens_details, :cached_tokens) ||
            ObjectReader.nested(usage, :prompt_tokens_details, :cached_tokens)
          )
        end

        def hidden_output_tokens(usage)
          ObjectReader.integer(
            ObjectReader.nested(usage, :output_tokens_details, :reasoning_tokens) ||
            ObjectReader.nested(usage, :completion_tokens_details, :reasoning_tokens)
          )
        end

        def regular_input_tokens(input_tokens, cache_read)
          [ObjectReader.integer(input_tokens) - cache_read.to_i, 0].max
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
      end
    end
  end
end
