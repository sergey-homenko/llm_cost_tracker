# frozen_string_literal: true

require_relative "base"

module LlmCostTracker
  module Integrations
    module RubyLlm
      extend Base

      class << self
        def integration_name = :ruby_llm

        def minimum_version = "1.14.1"

        def version_constant = "RubyLLM::VERSION"

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
            input_tokens = ObjectReader.first(response, :input_tokens)
            output_tokens = ObjectReader.first(response, :output_tokens) if output_tokens.nil?
            next if input_tokens.nil? && output_tokens.nil?

            cache_read = ObjectReader.integer(ObjectReader.first(response, :cached_tokens))

            LlmCostTracker::Tracker.record(
              provider: provider,
              model: model,
              input_tokens: regular_input_tokens(input_tokens, cache_read),
              output_tokens: ObjectReader.integer(output_tokens),
              latency_ms: latency_ms,
              stream: stream,
              usage_source: :ruby_llm,
              provider_response_id: provider_response_id(response),
              metadata: usage_metadata(response, cache_read)
            )
          end
        end

        def usage_metadata(response, cache_read)
          {
            cache_read_input_tokens: cache_read,
            cache_write_input_tokens: ObjectReader.integer(ObjectReader.first(response, :cache_creation_tokens)),
            hidden_output_tokens: ObjectReader.integer(
              ObjectReader.first(response, :thinking_tokens, :reasoning_tokens)
            )
          }
        end

        def regular_input_tokens(input_tokens, cache_read)
          [ObjectReader.integer(input_tokens) - cache_read.to_i, 0].max
        end

        def provider_slug(provider)
          ObjectReader.first(provider, :slug).to_s
        end

        def model_id(object)
          return nil if object.nil?

          value = ObjectReader.first(object, :id, :model_id, :model)
          value ||= object if object.is_a?(String) || object.is_a?(Symbol)
          value&.to_s
        end

        def response_model_id(object)
          value = ObjectReader.first(object, :model_id, :model)
          value&.to_s
        end

        def provider_response_id(response)
          ObjectReader.first(response, :id, :provider_response_id) || ObjectReader.nested(response, :raw, :id)
        end
      end

      module ProviderPatch
        def complete(*args, **kwargs, &)
          integration = LlmCostTracker::Integrations::RubyLlm
          request = integration.request_params(args, kwargs)
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          integration.enforce_budget!
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
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          integration.enforce_budget!
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
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          integration.enforce_budget!
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
