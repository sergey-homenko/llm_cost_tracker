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
            provider: provider.slug.to_s,
            model: response_model_id(response) || model_id_from_request(request[:model]),
            response: response,
            latency_ms: latency_ms,
            stream: has_block || request[:stream] == true
          )
        end

        def record_embedding(provider, response, request:, latency_ms:)
          record_usage(
            provider: provider.slug.to_s,
            model: response_model_id(response) || model_id_from_request(request[:model]),
            response: response,
            latency_ms: latency_ms,
            stream: false,
            output_tokens: 0
          )
        end

        def record_transcription(provider, response, request:, latency_ms:)
          record_usage(
            provider: provider.slug.to_s,
            model: response_model_id(response) || model_id_from_request(request[:model]),
            response: response,
            latency_ms: latency_ms,
            stream: false
          )
        end

        def record_image(provider, response, request:, latency_ms:)
          usage = response.usage.is_a?(Hash) ? response.usage.with_indifferent_access : {}
          raw_input = usage[:input_tokens].to_i
          raw_output = usage[:output_tokens].to_i
          image_input = image_token_detail(usage, :input)
          image_output = image_token_detail(usage, :output)
          text_input = [raw_input - image_input, 0].max
          text_output = [raw_output - image_output, 0].max
          record_passthrough(
            provider: provider.slug.to_s,
            model: response_model_id(response) || model_id_from_request(request[:model]),
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
            provider: provider.slug.to_s,
            model: response_model_id(response) || model_id_from_request(request[:model]),
            response: response,
            latency_ms: latency_ms,
            input_tokens: 0,
            output_tokens: 0
          )
        end

        def image_token_detail(usage, direction)
          container_key = direction == :input ? :input_tokens_details : :output_tokens_details
          details = usage[container_key]
          return 0 unless details.is_a?(Hash)

          details.with_indifferent_access[:image_tokens].to_i
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
                provider_response_id: provider_response_id_for(response)
              ),
              latency_ms: latency_ms
            )
          end
        end

        def record_usage(provider:, model:, response:, latency_ms:, stream:, output_tokens: nil)
          return unless active?

          record_safely do
            input_tokens = response.input_tokens
            output_tokens = response.output_tokens if output_tokens.nil?
            next if input_tokens.nil? && output_tokens.nil?

            cache_read = response.try(:cached_tokens).to_i
            cache_write = response.try(:cache_creation_tokens).to_i
            hidden_output = (response.try(:thinking_tokens) || response.try(:reasoning_tokens)).to_i

            LlmCostTracker::Tracker.record(
              event: Event.build(
                provider: provider,
                model: model,
                pricing_mode: pricing_mode_for(provider: provider, response: response),
                token_usage: TokenUsage.build(
                  input_tokens: regular_input_tokens(input_tokens, cache_read),
                  output_tokens: output_tokens.to_i,
                  cache_read_input_tokens: cache_read,
                  cache_write_input_tokens: cache_write,
                  hidden_output_tokens: hidden_output
                ),
                stream: stream,
                usage_source: :sdk_response,
                provider_response_id: provider_response_id_for(response)
              ),
              latency_ms: latency_ms
            )
          end
        end

        def regular_input_tokens(input_tokens, cache_read)
          [input_tokens.to_i - cache_read, 0].max
        end

        def model_id_from_request(value)
          return nil if value.nil?
          return value.to_s if value.is_a?(String) || value.is_a?(Symbol)

          (value.try(:id) || value.try(:model_id) || value.try(:model))&.to_s
        end

        def provider_response_id_for(response)
          response.try(:id) || response.try(:provider_response_id)
        end

        def response_model_id(response)
          (response.try(:model_id) || response.try(:model))&.to_s
        end

        def pricing_mode_for(provider:, response:)
          raw = response.try(:pricing_mode) || response.try(:service_tier)
          return nil if provider == "anthropic" &&
                        LlmCostTracker::Providers::Anthropic::TierClassification.standard_equivalent_tier?(raw)

          raw
        end

        def wrap_blocking_call(args, kwargs, resource, record_method:, **extras)
          request = request_params(args, kwargs)
          enforce_budget!(request: request)
          started_at = LlmCostTracker::Timing.now_monotonic
          response = yield
          public_send(
            record_method, resource, response,
            request: request,
            latency_ms: LlmCostTracker::Timing.elapsed_ms(started_at),
            **extras
          )
          response
        end
      end

      module ProviderPatch
        def complete(*args, **kwargs, &)
          LlmCostTracker::Integrations::RubyLlm.wrap_blocking_call(
            args, kwargs, self, record_method: :record_completion, has_block: block_given?
          ) { super }
        end

        def embed(*args, **kwargs)
          LlmCostTracker::Integrations::RubyLlm.wrap_blocking_call(
            args, kwargs, self, record_method: :record_embedding
          ) { super }
        end

        def transcribe(*args, **kwargs)
          LlmCostTracker::Integrations::RubyLlm.wrap_blocking_call(
            args, kwargs, self, record_method: :record_transcription
          ) { super }
        end

        def paint(*args, **kwargs)
          LlmCostTracker::Integrations::RubyLlm.wrap_blocking_call(
            args, kwargs, self, record_method: :record_image
          ) { super }
        end

        def moderate(*args, **kwargs)
          LlmCostTracker::Integrations::RubyLlm.wrap_blocking_call(
            args, kwargs, self, record_method: :record_moderation
          ) { super }
        end
      end
    end
  end
end
