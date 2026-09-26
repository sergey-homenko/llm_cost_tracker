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
            patch_target("RubyLLM::Providers::Gemini::Transcription", with: GeminiTranscriptionPatch, optional: true),
            patch_target("RubyLLM::Protocols::Gemini",
                         with: GeminiImagesPatch,
                         optional: true,
                         skip_when_methods_missing: true)
          ]
        end

        def record_completion(provider, response, request:, latency_ms:, has_block:)
          model = response_model_id(response) || model_id_from_request(request[:model])
          record_usage(
            provider: provider,
            model: model,
            response: response,
            latency_ms: latency_ms,
            stream: has_block || request[:stream] == true,
            service_line_items: server_tool_line_items(provider.slug.to_s, response, model)
          )
        end

        def server_tool_line_items(provider, response, model)
          body = raw_body(response)
          case provider
          when "anthropic"
            counts = response.try(:tokens).try(:server_tool_use) || body.dig("usage", "server_tool_use")
            Providers::Anthropic::UsageExtractor.service_line_items(server_tool_use: counts&.symbolize_keys)
          when "openai" then Providers::Openai::ServiceCharges.service_line_items_for(body, model: model)
          when "gemini" then Providers::Gemini::Parser.new.service_line_items_for(body, model: model)
          else []
          end
        end

        def record_embedding(provider, response, request:, latency_ms:)
          record_usage(
            provider: provider,
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
          counts = token_counts(response)
          duration = { type: "duration", seconds: response.duration } if counts[:input].nil? && counts[:output].nil?
          record_usage(
            provider: provider,
            model: model,
            response: response,
            latency_ms: latency_ms,
            stream: false,
            audio_input: match&.prices&.key?("audio_input"),
            service_line_items: Providers::Openai::ServiceCharges.transcription_line_items(duration)
          )
        end

        def record_image(provider, response, request:, latency_ms:)
          image = response.is_a?(Array) ? response.first : response
          model = response_model_id(image) || model_id_from_request(request[:model])
          usage = image_usage(image)
          extractor = Providers::Openai::UsageExtractor
          image_input = extractor.image_input_tokens(usage)
          image_output, text_output = extractor.split_output(
            output_tokens: usage[:output_tokens].to_i,
            image_output_details: gemini_image_output_tokens(image) || extractor.image_output_tokens(usage),
            text_output_details: extractor.text_output_tokens(usage),
            audio_output: 0,
            default_to_image: model.to_s.match?(/\A(gpt-image-|gemini-.*-image)/)
          )
          record_passthrough(
            provider: provider.slug.to_s,
            model: model,
            response: image,
            latency_ms: latency_ms,
            input_tokens: [usage[:input_tokens].to_i - image_input, 0].max,
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

        def image_usage(image)
          usage = image.try(:usage)
          usage = image.send(:raw_usage) if !usage.is_a?(Hash) && image.respond_to?(:raw_usage, true)
          (usage.is_a?(Hash) ? usage : {}).with_indifferent_access
        end

        def gemini_image_output_tokens(image)
          metadata = image.instance_variable_get(:@llm_cost_tracker_usage_metadata)
          Providers::Gemini::UsageExtractor.modality_tokens(metadata["candidatesTokensDetails"], "IMAGE") if metadata
        end

        def record_usage(provider:,
                         model:,
                         response:,
                         latency_ms:,
                         stream:,
                         output_tokens: nil,
                         audio_input: false,
                         service_line_items: [])
          return unless active?

          record_safely do
            counts = token_counts(response)
            output_tokens = counts[:output] if output_tokens.nil?
            next if counts[:input].nil? && output_tokens.nil? && service_line_items.empty?

            cache_write_5m, cache_write_1h = cache_write_split(provider.slug.to_s, response, counts[:cache_write])
            LlmCostTracker::Tracker.record(
              event: Event.build(
                provider: provider.slug.to_s,
                model: model,
                pricing_mode: pricing_mode_for(provider: provider, model: model, response: response),
                token_usage: gemini_token_usage(provider, response) || Usage::TokenUsage.build(
                  input_tokens: audio_input ? 0 : counts[:input].to_i,
                  audio_input_tokens: audio_input ? counts[:input].to_i : 0,
                  output_tokens: output_tokens.to_i,
                  cache_read_input_tokens: counts[:cache_read].to_i,
                  cache_write_input_tokens: cache_write_5m,
                  cache_write_extended_input_tokens: cache_write_1h,
                  hidden_output_tokens: counts[:thinking].to_i
                ),
                service_line_items: service_line_items,
                stream: stream,
                usage_source: LlmCostTracker::Usage::Source::SDK_RESPONSE,
                provider_response_id: provider_response_id_for(response)
              ),
              latency_ms: latency_ms
            )
          end
        end

        def gemini_token_usage(provider, response)
          usage = raw_body(response)["usageMetadata"] if provider.slug.to_s == "gemini"
          Providers::Gemini::UsageExtractor.token_usage(usage) if usage.is_a?(Hash)
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

          one_hour = cache["ephemeral_1h_input_tokens"].to_i
          # RubyLLM sums the writes of every pause_turn segment, but the raw body is only the last segment's.
          [[cache["ephemeral_5m_input_tokens"].to_i, cache_write.to_i - one_hour].max, one_hour]
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

        def pricing_mode_for(provider:, model:, response:)
          body = raw_body(response)
          case provider.slug.to_s
          when "anthropic"
            Providers::Anthropic::UsageExtractor.pricing_mode(request: nil, usage: body["usage"]&.deep_symbolize_keys)
          when "gemini" then body.dig("usageMetadata", "serviceTier")
          when "openai"
            Providers::Openai::ResponseParser.combined_pricing_mode(
              host: URI(provider.api_base).host, model: model, service_tier: body["service_tier"]
            )
          else body["service_tier"]
          end
        end

        def request_params(args, kwargs)
          input = args.first
          if input.is_a?(Array)
            input = input.map { |msg| msg.try(:content).then { |content| content.try(:text) || content } || msg }
          end
          kwargs.merge(input: input, model: model_id_from_request(kwargs[:model])).with_indifferent_access
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

      module GeminiImagesPatch
        def parse_image_responses(response, *, **)
          images = super
          metadata = response.body["usageMetadata"]
          Array(images).each { |image| image.instance_variable_set(:@llm_cost_tracker_usage_metadata, metadata) }
          images
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
