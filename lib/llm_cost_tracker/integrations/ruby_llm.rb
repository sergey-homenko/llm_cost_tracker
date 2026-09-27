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
                         skip_when_methods_missing: true),
            patch_target("RubyLLM::Protocols::Gemini",
                         with: GeminiCachePatch,
                         optional: true,
                         skip_when_methods_missing: true),
            patch_target("RubyLLM::Streaming", with: StreamPatch, optional: true),
            patch_target("RubyLLM::Protocol::Streaming", with: StreamPatch, optional: true),
            *%w[RubyLLM::Providers::OpenAI RubyLLM::Providers::Gemini
                RubyLLM::Protocols::ChatCompletions RubyLLM::Protocols::Gemini].map do |name|
              patch_target(name, with: ResponseBodyPatch, optional: true, skip_when_methods_missing: true)
            end
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
            cache_ttl: request[:caching].try(:[], :ttl),
            service_line_items: service_line_items(provider.slug.to_s, response, model)
          )
        end

        def service_line_items(provider, response, model)
          body = raw_body(response)
          case provider
          when "anthropic"
            counts = response.try(:tokens).try(:server_tool_use) || body.dig("usage", "server_tool_use")
            Providers::Anthropic::UsageExtractor.service_line_items(server_tool_use: counts&.symbolize_keys)
          when "openai" then Providers::Openai::ServiceCharges.service_line_items_for(body, model: model)
          when "gemini" then Providers::Gemini::Parser.new.service_line_items_for(gemini_body(response), model: model)
          when "openrouter" then Providers::Openai::ServiceCharges.billed_line_items(usage_hash(body))
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
            output_tokens: 0,
            service_line_items: gemini_video_line_items(provider, response)
          )
        end

        def gemini_video_line_items(provider, response)
          details = raw_body(response).dig("usageMetadata", "promptTokenDetails") if provider.slug.to_s == "gemini"
          video = Providers::Gemini::UsageExtractor.modality_tokens(details, "VIDEO")
          video.positive? ? [Charges::LineItem.build(dimension_key: "video_input", quantity: video)] : []
        end

        def record_transcription(provider, response, request:, latency_ms:, stream: false)
          model = response_model_id(response) || model_id_from_request(request[:model])
          match = LlmCostTracker::Pricing::Matcher.lookup(provider: provider.slug.to_s, model: model)
          counts = token_counts(response)
          usage = usage_hash(raw_body(response))
          no_tokens = counts[:input].to_i.zero? && counts[:output].to_i.zero?
          duration = billed_duration(usage, response, no_tokens)
          line_items = Providers::Openai::ServiceCharges.transcription_line_items(duration)
          audio_input = Providers::Openai::UsageExtractor.audio_input_tokens(usage)
          audio_input = counts[:input].to_i if audio_input.zero? && match&.prices&.key?("audio_input")
          record_usage(
            provider: provider,
            model: model,
            response: response,
            latency_ms: latency_ms,
            stream: stream,
            audio_input_tokens: audio_input,
            service_line_items: line_items,
            usage_source: (Usage::Source::UNKNOWN if no_tokens && line_items.empty?)
          )
        end

        def billed_duration(usage, response, no_tokens)
          return usage if usage[:type].to_s == "duration"

          { type: "duration", seconds: response.duration&.ceil } if no_tokens
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

        def record_cache_storage(cache)
          return unless active? && cache.provider.to_s == "gemini"

          record_safely do
            event = Providers::Gemini::Parser.new.cache_storage_event(cache.metadata)
            LlmCostTracker::Tracker.record(event: event) if event
          end
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
                         audio_input_tokens: 0,
                         cache_ttl: nil,
                         service_line_items: [],
                         usage_source: nil)
          return unless active?

          record_safely do
            counts = token_counts(response, provider.slug.to_s)
            output_tokens = counts[:output] if output_tokens.nil?
            next if counts[:input].nil? && output_tokens.nil? && service_line_items.empty? && usage_source.nil?

            cache_write_5m, cache_write_1h = cache_write_split(provider, response, counts[:cache_write], cache_ttl)
            LlmCostTracker::Tracker.record(
              event: Event.build(
                provider: provider.slug.to_s,
                model: model,
                pricing_mode: pricing_mode_for(provider: provider, model: model, response: response),
                token_usage: gemini_token_usage(provider, response) || Usage::TokenUsage.build(
                  input_tokens: counts[:input].to_i - audio_input_tokens,
                  audio_input_tokens: audio_input_tokens,
                  output_tokens: output_tokens.to_i,
                  cache_read_input_tokens: counts[:cache_read].to_i,
                  cache_write_input_tokens: cache_write_5m,
                  cache_write_extended_input_tokens: cache_write_1h,
                  hidden_output_tokens: counts[:thinking].to_i
                ),
                service_line_items: service_line_items + gemini_cache_read_line_items(provider, response),
                stream: stream,
                usage_source: usage_source || LlmCostTracker::Usage::Source::SDK_RESPONSE,
                provider_response_id: provider_response_id_for(response)
              ),
              latency_ms: latency_ms
            )
          end
        end

        def gemini_token_usage(provider, response)
          usage = gemini_usage_metadata(response) if provider.slug.to_s == "gemini"
          return unless usage.is_a?(Hash)

          usage = usage.merge("promptTokensDetails" => usage["promptTokenDetails"]) if usage.key?("promptTokenDetails")
          Providers::Gemini::UsageExtractor.token_usage(usage)
        end

        def gemini_cache_read_line_items(provider, response)
          usage = gemini_usage_metadata(response) if provider.slug.to_s == "gemini"
          usage.is_a?(Hash) ? Providers::Gemini::UsageExtractor.cache_read_line_items(usage) : []
        end

        def gemini_body(response)
          content = response.try(:raw_content)
          interaction = content["response"] if content.is_a?(Hash)
          interaction.is_a?(Hash) && interaction["usage"].is_a?(Hash) ? interaction : raw_body(response)
        end

        def gemini_usage_metadata(response)
          body = gemini_body(response)
          return body["usageMetadata"] unless body["usage"].is_a?(Hash)

          Providers::Gemini::Parser.new.interaction_usage_metadata(body["usage"], body["service_tier"])
        end

        def token_counts(response, provider = nil)
          tokens = response.try(:tokens)
          return { input: response.try(:input_tokens), output: response.try(:output_tokens) } unless tokens

          usage = raw_body(response)["usage"] || {}
          input = usage["inputTokens"] || tokens.input
          input = [input, usage["input_tokens"]].compact.max if provider == "anthropic"
          output = tokens.output
          thinking = tokens.thinking.to_i
          raw_input = (usage["input_tokens"] || usage["prompt_tokens"]).to_i
          output += thinking if output && usage["total_tokens"] == raw_input + output + thinking
          {
            input: input,
            output: output,
            cache_read: tokens.cache_read,
            cache_write: tokens.cache_write,
            thinking: tokens.thinking
          }
        end

        def cache_write_split(provider, response, cache_write, cache_ttl)
          usage = raw_body(response)["usage"] || {}
          cache = case provider.slug.to_s
                  when "anthropic" then usage["cache_creation"]
                  when "bedrock"
                    Array(usage["cacheDetails"]).to_h { |d| ["ephemeral_#{d['ttl']}_input_tokens", d["inputTokens"]] }
                  end
          return [cache_write.to_i, 0] unless cache.is_a?(Hash)

          five_minute = cache["ephemeral_5m_input_tokens"].to_i
          one_hour = cache["ephemeral_1h_input_tokens"].to_i
          # RubyLLM sums the writes of every pause_turn segment, but the raw body is only the last segment's.
          earlier = [cache_write.to_i - five_minute - one_hour, 0].max
          cache_ttl.to_s == "1h" ? [five_minute, one_hour + earlier] : [five_minute + earlier, one_hour]
        end

        def model_id_from_request(value)
          return nil if value.nil?
          return value.to_s if value.is_a?(String) || value.is_a?(Symbol)

          (value.try(:id) || value.try(:model_id) || value.try(:model))&.to_s
        end

        def provider_response_id_for(response)
          body = gemini_body(response)
          body["id"] || body["responseId"]
        end

        def raw_body(response)
          raw = response.try(:raw)
          body = raw.respond_to?(:body) ? raw.body : raw
          body = (raw || response).instance_variable_get(:@llm_cost_tracker_body) unless body.is_a?(Hash)
          body.is_a?(Hash) ? body : {}
        end

        def usage_hash(body) = (body["usage"] || {}).deep_symbolize_keys

        def keep_usage(result, body)
          usage = body.slice("usage", "usageMetadata") if body.is_a?(Hash)
          result.instance_variable_set(:@llm_cost_tracker_body, usage) if usage
          result
        end

        def response_model_id(response)
          (response.try(:model_id) || response.try(:model))&.to_s
        end

        def pricing_mode_for(provider:, model:, response:)
          body = raw_body(response)
          case provider.slug.to_s
          when "anthropic", "bedrock"
            Providers::Anthropic::UsageExtractor.pricing_mode(request: { model: model },
                                                              usage: body["usage"]&.deep_symbolize_keys)
          when "gemini" then gemini_usage_metadata(response).try(:[], "serviceTier")
          when "openai", "xai", "mistral"
            Providers::Openai::ResponseParser.combined_pricing_mode(
              provider: provider.slug.to_s,
              host: URI(provider.api_base).host,
              model: model,
              service_tier: body["service_tier"] || body.dig("usage", "service_tier")
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

        def transcribe(*args, **kwargs, &)
          seam = LlmCostTracker::Integrations::RubyLlm.blocking_seam(self, :record_transcription, stream: block_given?)
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

      module GeminiCachePatch
        def cache_content(*, **)
          super.tap { |cache| LlmCostTracker::Integrations::RubyLlm.record_cache_storage(cache) }
        end
      end

      module GeminiTranscriptionPatch
        def transcribe(*args, **kwargs)
          seam = LlmCostTracker::Integrations::RubyLlm.blocking_seam(self, :record_transcription)
          LlmCostTracker::Integrations::RubyLlm.wrap_blocking(args, kwargs, **seam) { super }
        end
      end

      module ResponseBodyPatch
        def parse_transcription_response(response, **)
          LlmCostTracker::Integrations::RubyLlm.keep_usage(super, response.body)
        end

        def parse_embedding_response(response, **)
          LlmCostTracker::Integrations::RubyLlm.keep_usage(super, response.body)
        end

        def build_streamed_transcription(chunks, **)
          LlmCostTracker::Integrations::RubyLlm.keep_usage(super, chunks.reverse.find(&:done?)&.raw)
        end
      end

      module StreamPatch
        private

        def stream_response(...)
          body = @llm_cost_tracker_stream_body = {}
          super.tap do |message|
            message.raw.instance_variable_set(:@llm_cost_tracker_body, body)
            input = body.dig("usage", "input_tokens")
            input = body["usage"]["input_tokens"] = input + @llm_cost_tracker_paused_input.to_i if input
            @llm_cost_tracker_paused_input = (input if message.try(:finish_reason) == :pause_turn)
          end
        end

        def build_on_data_handler(*, &handler)
          body = @llm_cost_tracker_stream_body
          super do |data|
            if body && data.is_a?(Hash)
              body.deep_merge!(data.values_at("message", "response").find { |part| part.is_a?(Hash) } || data)
            end
            handler.call(data)
          end
        end
      end
    end
  end
end
