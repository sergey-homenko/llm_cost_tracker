# frozen_string_literal: true

require_relative "../base"
require_relative "v1/patches"
require_relative "v1/reply"

module LlmCostTracker
  module Integrations
    module RubyLlm
      module V1
        extend Base

        minimum_version "1.15.0"
        maximum_version "2.0.0"

        class << self
          def integration_name = :ruby_llm

          def patch_targets
            [
              patch_target("RubyLLM::Provider", with: ProviderPatch),
              patch_target("RubyLLM::Providers::Gemini::Transcription", with: GeminiTranscriptionPatch, optional: true),
              patch_target("RubyLLM::Streaming", with: StreamPatch, optional: true),
              *%w[RubyLLM::Providers::OpenAI RubyLLM::Providers::Gemini].map do |name|
                patch_target(name, with: ResponseBodyPatch, optional: true, skip_when_methods_missing: true)
              end
            ]
          end

          def blocking_seam(resource, record_method, **extras)
            {
              provider: resource.slug.to_s,
              record: lambda do |response, request, latency_ms|
                public_send(record_method, resource, response, request: request, latency_ms: latency_ms, **extras)
              end
            }
          end

          def request_params(args, kwargs)
            input = args.first
            if input.is_a?(Array)
              input = input.map { |msg| msg.try(:content).then { |content| content.try(:text) || content } || msg }
            end
            kwargs.merge(input: input, model: model_id_from_request(kwargs[:model])).with_indifferent_access
          end

          def provider_response_id_for(response) = Reply.response_id(response)

          def keep_usage(result, body)
            usage = body.slice("usage", "usageMetadata") if body.is_a?(Hash)
            result.instance_variable_set(Reply::KEPT_BODY, usage) if usage
            result
          end

          def record_completion(provider, response, request:, latency_ms:, has_block:)
            reply = reply_for(provider, response, request)
            stream = has_block || request[:stream] == true
            record_usage(reply, latency_ms, stream: stream, service_line_items: reply.service_line_items)
          end

          def record_embedding(provider, response, request:, latency_ms:)
            return unless active?

            record_usage(reply_for(provider, response, request), latency_ms, stream: false, output_tokens: 0)
          end

          def record_transcription(provider, response, request:, latency_ms:)
            reply = reply_for(provider, response, request)
            counts = reply.token_counts
            no_tokens = counts[:input].to_i.zero? && counts[:output].to_i.zero?
            duration = billed_duration(reply.usage, response, no_tokens)
            line_items = Providers::Openai::ServiceCharges.transcription_line_items(duration)
            record_usage(
              reply,
              latency_ms,
              stream: false,
              audio_input_tokens: audio_input_tokens(reply, counts),
              service_line_items: line_items,
              usage_source: (Usage::Source::UNKNOWN if no_tokens && line_items.empty?)
            )
          end

          def record_image(provider, response, request:, latency_ms:)
            reply = reply_for(provider, response, request)
            usage = response.try(:usage)
            usage = (usage.is_a?(Hash) ? usage : {}).with_indifferent_access
            record_passthrough(
              provider: reply.slug,
              model: reply.model,
              response: response,
              latency_ms: latency_ms,
              usage_source: usage.empty? ? Usage::Source::UNKNOWN : Usage::Source::SDK_RESPONSE,
              **image_tokens(usage, reply.model)
            )
          end

          def record_moderation(provider, response, request:, latency_ms:)
            reply = reply_for(provider, response, request)
            record_passthrough(
              provider: reply.slug, model: reply.model, response:, latency_ms:, input_tokens: 0, output_tokens: 0
            )
          end

          private

          def reply_for(provider, response, request)
            Reply.new(provider, response, model_id_from_request(request[:model]))
          end

          def model_id_from_request(value)
            return value.to_s if value.is_a?(String) || value.is_a?(Symbol)

            (value.try(:id) || value.try(:model_id) || value.try(:model))&.to_s
          end

          def record_usage(reply, latency_ms, **options)
            return unless active?

            record_safely do
              event = reply.event(**options)
              LlmCostTracker::Tracker.record(event: event, latency_ms: latency_ms) if event
            end
          end

          def billed_duration(usage, response, no_tokens)
            return usage if usage[:type].to_s == "duration" || usage[:prompt_audio_seconds]

            { type: "duration", seconds: response.duration&.ceil } if no_tokens
          end

          def audio_input_tokens(reply, counts)
            tokens = Providers::Openai::UsageExtractor.audio_input_tokens(reply.usage)
            match = Pricing::Matcher.lookup(provider: reply.slug, model: reply.model) if tokens.zero?
            match&.prices&.key?("audio_input") ? counts[:input].to_i : tokens
          end

          def image_tokens(usage, model)
            extractor = Providers::Openai::UsageExtractor
            image_input = extractor.image_input_tokens(usage)
            image_output, text_output = extractor.split_output(
              output_tokens: usage[:output_tokens].to_i,
              image_output_details: extractor.image_output_tokens(usage),
              text_output_details: extractor.text_output_tokens(usage),
              audio_output: 0,
              default_to_image: model.to_s.match?(/\A(gpt-image-|gemini-.*-image)/)
            )
            { input_tokens: [usage[:input_tokens].to_i - image_input, 0].max, image_input_tokens: image_input,
              output_tokens: text_output, image_output_tokens: image_output }
          end
        end
      end
    end
  end
end
