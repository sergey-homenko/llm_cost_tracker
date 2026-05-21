# frozen_string_literal: true

require_relative "base"
require_relative "../providers/anthropic/tier_classification"

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
              methods: %i[slug complete embed transcribe paint moderate]
            )
          ]
        end

        def record_completion(provider, response, request:, latency_ms:, has_block:)
          record_usage(
            provider: provider_slug(provider),
            model: response_model_id(response) || model_id(request[:model]),
            response: response,
            latency_ms: latency_ms,
            stream: has_block || request[:stream] == true
          )
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

        def record_image(provider, response, request:, latency_ms:)
          usage = object_value(response, :usage)
          usage = {} unless usage.is_a?(Hash)
          raw_input = (usage[:input_tokens] || usage["input_tokens"]).to_i
          raw_output = (usage[:output_tokens] || usage["output_tokens"]).to_i
          image_input = image_token_detail(usage, :input)
          image_output = image_token_detail(usage, :output)
          text_input = [raw_input - image_input, 0].max
          text_output = [raw_output - image_output, 0].max
          record_passthrough(
            provider: provider_slug(provider),
            model: response_model_id(response) || model_id(request[:model]),
            response: response,
            latency_ms: latency_ms,
            input_tokens: text_input,
            image_input_tokens: image_input,
            output_tokens: text_output,
            image_output_tokens: image_output
          )
        end

        def record_moderation(provider, response, request:, latency_ms:)
          record_passthrough(
            provider: provider_slug(provider),
            model: response_model_id(response) || model_id(request[:model]),
            response: response,
            latency_ms: latency_ms,
            input_tokens: 0,
            output_tokens: 0
          )
        end

        def image_token_detail(usage, direction)
          container_key = direction == :input ? :input_tokens_details : :output_tokens_details
          details = usage[container_key] || usage[container_key.to_s] || {}
          return 0 unless details.is_a?(Hash)

          (details[:image_tokens] || details["image_tokens"]).to_i
        end

        def record_passthrough(provider:, model:, response:, latency_ms:, input_tokens:, output_tokens:,
                               image_input_tokens: 0, image_output_tokens: 0)
          return unless active?

          record_safely do
            LlmCostTracker::Tracker.record(
              event: Event.build(
                provider: provider,
                model: model,
                token_usage: TokenUsage.build(
                  input_tokens: input_tokens,
                  output_tokens: output_tokens,
                  image_input_tokens: image_input_tokens,
                  image_output_tokens: image_output_tokens
                ),
                usage_source: :sdk_response,
                provider_response_id: provider_response_id(response)
              ),
              latency_ms: latency_ms
            )
          end
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
              event: Event.build(
                provider: provider,
                model: model,
                pricing_mode: pricing_mode(provider: provider, response: response),
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
          object_value(response, :id, :provider_response_id)
        end

        def pricing_mode(provider:, response:)
          raw = object_value(response, :pricing_mode, :service_tier)
          if provider == "anthropic" && LlmCostTracker::Providers::Anthropic::TierClassification.standard_equivalent_tier?(raw)
            return nil
          end

          raw
        end
      end

      module ProviderPatch
        def complete(*args, **kwargs, &)
          measure(args, kwargs, recorder: :record_completion, has_block: block_given?) { super }
        end

        def embed(*args, **kwargs)
          measure(args, kwargs, recorder: :record_embedding) { super }
        end

        def transcribe(*args, **kwargs)
          measure(args, kwargs, recorder: :record_transcription) { super }
        end

        def paint(*args, **kwargs)
          measure(args, kwargs, recorder: :record_image) { super }
        end

        def moderate(*args, **kwargs)
          measure(args, kwargs, recorder: :record_moderation) { super }
        end

        private

        def measure(args, kwargs, recorder:, **extras)
          request = RubyLlm.request_params(args, kwargs)
          RubyLlm.enforce_budget!(request: request)
          started_at = LlmCostTracker::Timing.now_monotonic
          response = yield
          RubyLlm.public_send(
            recorder, self, response,
            request: request,
            latency_ms: LlmCostTracker::Timing.elapsed_ms(started_at),
            **extras
          )
          response
        end
      end
    end
  end
end
