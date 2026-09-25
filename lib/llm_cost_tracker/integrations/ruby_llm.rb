# frozen_string_literal: true

require_relative "base"

module LlmCostTracker
  module Integrations
    module RubyLlm
      extend Base

      minimum_version "1.15.0"
      maximum_version "3.0.0"

      class << self
        def patch_targets
          [
            patch_target("RubyLLM::Provider", with: ProviderPatch),
            patch_target("RubyLLM::Providers::Gemini::Transcription", with: GeminiTranscriptionPatch, optional: true)
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
          model = response_model_id(response) || model_id_from_request(request[:model])
          match = LlmCostTracker::Pricing::Matcher.lookup(provider: provider.slug.to_s, model: model)
          record_usage(
            provider: provider.slug.to_s,
            model: model,
            response: response,
            latency_ms: latency_ms,
            stream: false,
            audio_input: match&.prices&.key?("audio_input")
          )
        end

        def record_image(provider, response, request:, latency_ms:)
          image = response.is_a?(Array) ? response.first : response
          usage = image_usage(image)
          raw_input = usage[:input_tokens].to_i
          raw_output = usage[:output_tokens].to_i
          image_input = image_token_detail(usage, :input)
          image_output = image_token_detail(usage, :output)
          record_passthrough(
            provider: provider.slug.to_s,
            model: response_model_id(image) || model_id_from_request(request[:model]),
            response: image,
            latency_ms: latency_ms,
            input_tokens: [raw_input - image_input, 0].max,
            image_input_tokens: image_input,
            output_tokens: [raw_output - image_output, 0].max,
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

        def image_usage(image)
          usage = image.try(:usage)
          usage = image.send(:raw_usage) if !usage.is_a?(Hash) && image.respond_to?(:raw_usage, true)
          (usage.is_a?(Hash) ? usage : {}).with_indifferent_access
        end

        def image_token_detail(usage, direction)
          container_key = direction == :input ? :input_tokens_details : :output_tokens_details
          details = usage[container_key]
          return 0 unless details.is_a?(Hash)

          details.with_indifferent_access[:image_tokens].to_i
        end

        def record_passthrough(provider:,
                               model:,
                               response:,
                               latency_ms:,
                               input_tokens:,
                               output_tokens:,
                               image_input_tokens: 0,
                               image_output_tokens: 0)
          return unless active?

          record_safely do
            LlmCostTracker::Tracker.record(
              event: Event.build(
                provider: provider,
                model: model,
                token_usage: Usage::TokenUsage.build(
                  input_tokens: input_tokens,
                  output_tokens: output_tokens,
                  image_input_tokens: image_input_tokens,
                  image_output_tokens: image_output_tokens
                ),
                usage_source: LlmCostTracker::Usage::Source::SDK_RESPONSE,
                provider_response_id: provider_response_id_for(response)
              ),
              latency_ms: latency_ms
            )
          end
        end

        def record_usage(provider:, model:, response:, latency_ms:, stream:, output_tokens: nil, audio_input: false)
          return unless active?

          record_safely do
            counts = token_counts(response)
            input_tokens = counts[:input]
            output_tokens = counts[:output] if output_tokens.nil?
            next if input_tokens.nil? && output_tokens.nil?

            cache_write_5m, cache_write_1h = cache_write_split(provider, response, counts[:cache_write])
            LlmCostTracker::Tracker.record(
              event: Event.build(
                provider: provider,
                model: model,
                pricing_mode: pricing_mode_for(provider: provider, response: response),
                token_usage: Usage::TokenUsage.build(
                  input_tokens: audio_input ? 0 : input_tokens.to_i,
                  audio_input_tokens: audio_input ? input_tokens.to_i : 0,
                  output_tokens: output_tokens.to_i,
                  cache_read_input_tokens: counts[:cache_read].to_i,
                  cache_write_input_tokens: cache_write_5m,
                  cache_write_extended_input_tokens: cache_write_1h,
                  hidden_output_tokens: counts[:thinking].to_i
                ),
                stream: stream,
                usage_source: LlmCostTracker::Usage::Source::SDK_RESPONSE,
                provider_response_id: provider_response_id_for(response)
              ),
              latency_ms: latency_ms
            )
          end
        end

        def token_counts(response)
          tokens = response.try(:tokens)
          return { input: response.try(:input_tokens), output: response.try(:output_tokens) } unless tokens

          {
            input: tokens.input,
            output: tokens.output,
            cache_read: tokens.cache_read,
            cache_write: tokens.cache_write,
            thinking: tokens.thinking
          }
        end

        def cache_write_split(provider, response, cache_write)
          cache = raw_body(response).dig("usage", "cache_creation") if provider == "anthropic"
          return [cache_write.to_i, 0] unless cache.is_a?(Hash)

          [cache["ephemeral_5m_input_tokens"].to_i, cache["ephemeral_1h_input_tokens"].to_i]
        end

        def model_id_from_request(value)
          return nil if value.nil?
          return value.to_s if value.is_a?(String) || value.is_a?(Symbol)

          (value.try(:id) || value.try(:model_id) || value.try(:model))&.to_s
        end

        def provider_response_id_for(response)
          body = raw_body(response)
          body["id"] || body["responseId"]
        end

        def raw_body(response)
          raw = response.try(:raw)
          body = raw.respond_to?(:body) ? raw.body : raw
          body.is_a?(Hash) ? body : {}
        end

        def response_model_id(response)
          (response.try(:model_id) || response.try(:model))&.to_s
        end

        def pricing_mode_for(provider:, response:)
          body = raw_body(response)
          case provider
          when "anthropic" then body.dig("usage", "service_tier")
          when "gemini" then body.dig("usageMetadata", "serviceTier")
          else body["service_tier"]
          end
        end

        def blocking_seam(resource, record_method, **extras)
          {
            provider: resource.slug.to_s,
            record: lambda do |response, request, latency_ms|
              public_send(record_method, resource, response, request: request, latency_ms: latency_ms, **extras)
            end
          }
        end
      end

      module ProviderPatch
        def complete(*args, **kwargs, &)
          seam = LlmCostTracker::Integrations::RubyLlm.blocking_seam(self, :record_completion, has_block: block_given?)
          LlmCostTracker::Integrations::RubyLlm.wrap_blocking(args, kwargs, **seam) { super }
        end

        def embed(*args, **kwargs)
          seam = LlmCostTracker::Integrations::RubyLlm.blocking_seam(self, :record_embedding)
          LlmCostTracker::Integrations::RubyLlm.wrap_blocking(args, kwargs, **seam) { super }
        end

        def transcribe(*args, **kwargs)
          seam = LlmCostTracker::Integrations::RubyLlm.blocking_seam(self, :record_transcription)
          LlmCostTracker::Integrations::RubyLlm.wrap_blocking(args, kwargs, **seam) { super }
        end

        def paint(*args, **kwargs)
          seam = LlmCostTracker::Integrations::RubyLlm.blocking_seam(self, :record_image)
          LlmCostTracker::Integrations::RubyLlm.wrap_blocking(args, kwargs, **seam) { super }
        end

        def moderate(*args, **kwargs)
          seam = LlmCostTracker::Integrations::RubyLlm.blocking_seam(self, :record_moderation)
          LlmCostTracker::Integrations::RubyLlm.wrap_blocking(args, kwargs, **seam) { super }
        end
      end

      module GeminiTranscriptionPatch
        def transcribe(*args, **kwargs)
          seam = LlmCostTracker::Integrations::RubyLlm.blocking_seam(self, :record_transcription)
          LlmCostTracker::Integrations::RubyLlm.wrap_blocking(args, kwargs, **seam) { super }
        end
      end
    end
  end
end
