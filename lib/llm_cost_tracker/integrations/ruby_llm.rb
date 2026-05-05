# frozen_string_literal: true

require_relative "base"

module LlmCostTracker
  module Integrations
    module RubyLlm
      extend Base

      class << self
        def integration_name
          :ruby_llm
        end

        def minimum_version
          "1.14.1"
        end

        def version_constant
          "RubyLLM::VERSION"
        end

        def patch_targets
          [
            patch_target(
              "RubyLLM::Provider",
              with: ProviderPatch,
              methods: %i[slug complete embed transcribe]
            )
          ]
        end

        def record_completion(provider, response, request:, latency_ms:, stream:)
          record_usage(
            provider: provider_slug(provider),
            model: response_model_id(response) || model_id(request[:model]),
            response: response,
            latency_ms: latency_ms,
            stream: stream
          )
        end

        def streaming_request?(request, has_block:)
          has_block || request[:stream] == true
        end

        def record_embedding(provider, response, request:, latency_ms:)
          record_usage(
            provider: provider_slug(provider),
            model: response_model_id(response) || model_id(request[:model]),
            response: response,
            latency_ms: latency_ms,
            stream: false,
            output_tokens: 0
          )
        end

        def record_transcription(provider, response, request:, latency_ms:)
          record_usage(
            provider: provider_slug(provider),
            model: response_model_id(response) || model_id(request[:model]),
            response: response,
            latency_ms: latency_ms,
            stream: false
          )
        end

        def record_usage(provider:, model:, response:, latency_ms:, stream:, output_tokens: nil)
          return unless active?

          record_safely do
            input_tokens = object_value(response, :input_tokens)
            output_tokens = object_value(response, :output_tokens) if output_tokens.nil?
            next if input_tokens.nil? && output_tokens.nil?

            cache_read = object_value(response, :cached_tokens).to_i
            hidden_output = object_value(response, :thinking_tokens, :reasoning_tokens).to_i

            LlmCostTracker::Tracker.record(
              capture: UsageCapture.build(
                provider: provider,
                model: model,
                pricing_mode: pricing_mode(response),
                token_usage: TokenUsage.build(
                  input_tokens: regular_input_tokens(input_tokens, cache_read),
                  output_tokens: output_tokens.to_i,
                  cache_read_input_tokens: cache_read,
                  cache_write_input_tokens: object_value(response, :cache_creation_tokens).to_i,
                  hidden_output_tokens: hidden_output
                ),
                stream: stream,
                usage_source: :sdk_response,
                provider_response_id: provider_response_id(response)
              ),
              latency_ms: latency_ms
            )
          end
        end

        def regular_input_tokens(input_tokens, cache_read)
          [input_tokens.to_i - cache_read, 0].max
        end

        def provider_slug(provider)
          object_value(provider, :slug).to_s
        end

        def model_id(object)
          return nil if object.nil?

          value = object_value(object, :id, :model_id, :model)
          value ||= object if object.is_a?(String) || object.is_a?(Symbol)
          value&.to_s
        end

        def response_model_id(object)
          value = object_value(object, :model_id, :model)
          value&.to_s
        end

        def provider_response_id(response)
          object_value(response, :id, :provider_response_id) || object_dig(response, :raw, :id)
        end

        def pricing_mode(response)
          object_value(response, :pricing_mode, :service_tier) ||
            object_dig(response, :raw, :pricing_mode) ||
            object_dig(response, :raw, :service_tier)
        end
      end

      module ProviderPatch
        def complete(*args, **kwargs, &)
          integration = LlmCostTracker::Integrations::RubyLlm
          request = integration.request_params(args, kwargs)
          integration.enforce_budget!
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          response = super
          integration.record_completion(
            self,
            response,
            request: request,
            latency_ms: integration.elapsed_ms(started_at),
            stream: integration.streaming_request?(request, has_block: block_given?)
          )
          response
        end

        def embed(*args, **kwargs)
          integration = LlmCostTracker::Integrations::RubyLlm
          request = integration.request_params(args, kwargs)
          integration.enforce_budget!
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          response = super
          integration.record_embedding(
            self,
            response,
            request: request,
            latency_ms: integration.elapsed_ms(started_at)
          )
          response
        end

        def transcribe(*args, **kwargs)
          integration = LlmCostTracker::Integrations::RubyLlm
          request = integration.request_params(args, kwargs)
          integration.enforce_budget!
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          response = super
          integration.record_transcription(
            self,
            response,
            request: request,
            latency_ms: integration.elapsed_ms(started_at)
          )
          response
        end
      end
    end
  end
end
