# frozen_string_literal: true

module LlmCostTracker
  module Integrations
    module RubyLlm
      module V1
        class Reply
          KEPT_BODY = :@llm_cost_tracker_body

          attr_reader :slug, :model

          def self.body(response)
            raw = response.try(:raw)
            body = raw.respond_to?(:body) ? raw.body : raw
            body = (raw || response).instance_variable_get(KEPT_BODY) unless body.is_a?(Hash)
            body.is_a?(Hash) ? body : {}
          end

          def self.response_id(response)
            body = body(response)
            body["id"] || body["responseId"]
          end

          def initialize(provider, response, requested_model)
            @provider = provider
            @response = response
            @slug = provider.slug.to_s
            @model = (response.try(:model_id) || response.try(:model))&.to_s || requested_model
            @body = Reply.body(response)
          end

          def usage = @usage ||= (@body["usage"] || {}).deep_symbolize_keys

          def event(stream:, output_tokens: nil, audio_input_tokens: 0, service_line_items: [], usage_source: nil)
            counts = token_counts
            output_tokens = counts[:output] if output_tokens.nil?
            return if counts[:input].nil? && output_tokens.nil? && service_line_items.empty? && usage_source.nil?

            Event.build(
              provider: @slug,
              model: @model,
              pricing_mode: pricing_mode,
              token_usage: token_usage(counts, output_tokens, audio_input_tokens),
              service_line_items: service_line_items + gemini_line_items,
              stream: stream,
              usage_source: usage_source || Usage::Source::SDK_RESPONSE,
              provider_response_id: Reply.response_id(@response)
            )
          end

          def service_line_items
            case @slug
            when "anthropic"
              server_tool_use = @body.dig("usage", "server_tool_use")&.symbolize_keys
              Providers::Anthropic::UsageExtractor.service_line_items(server_tool_use: server_tool_use)
            when "openai" then Providers::Openai::ServiceCharges.service_line_items_for(@body, model: @model)
            when "gemini" then Providers::Gemini::Parser.new.service_line_items_for(@body, model: @model)
            when "openrouter", "xai", "perplexity" then Providers::Openai::ServiceCharges.billed_line_items(usage)
            else []
            end
          end

          def token_counts
            tokens = @response.try(:tokens)
            return { input: @response.try(:input_tokens), output: @response.try(:output_tokens) } unless tokens

            usage = @body["usage"] || {}
            { input: input_tokens(tokens, usage), output: output_tokens(tokens, usage), cache_read: tokens.cache_read,
              cache_write: tokens.cache_write, thinking: tokens.thinking }
          end

          private

          def token_usage(counts, output_tokens, audio_input_tokens)
            gemini = gemini_usage
            return Providers::Gemini::UsageExtractor.token_usage(gemini) if gemini

            five_minute, one_hour = cache_writes(counts[:cache_write])
            Usage::TokenUsage.build(
              input_tokens: counts[:input].to_i - audio_input_tokens,
              audio_input_tokens: audio_input_tokens,
              output_tokens: output_tokens.to_i,
              cache_read_input_tokens: counts[:cache_read].to_i,
              cache_write_input_tokens: five_minute,
              cache_write_extended_input_tokens: one_hour,
              hidden_output_tokens: counts[:thinking].to_i
            )
          end

          def gemini_line_items
            gemini = gemini_usage
            gemini ? Providers::Gemini::UsageExtractor.line_items(gemini) : []
          end

          def pricing_mode
            case @slug
            when "anthropic", "bedrock"
              Providers::Anthropic::UsageExtractor.pricing_mode(
                request: { model: @model, service_tier: @body["serviceTier"].try(:[], "type") },
                usage: @body["usage"]&.deep_symbolize_keys
              )
            when "gemini", "vertexai"
              Providers::Gemini::Parser.new.pricing_mode(
                request: {}, usage: @body["usageMetadata"], response_headers: nil, host: host, model: @model
              )
            when "openai", "xai", "mistral"
              service_tier = @body["service_tier"] || @body.dig("usage", "service_tier")
              Providers::Openai::ResponseParser.combined_pricing_mode(
                provider: @slug, host: host, model: @model, service_tier: service_tier
              )
            else @body["service_tier"]
            end
          end

          def host = URI(@provider.api_base).host

          def gemini_usage
            gemini = @body["usageMetadata"] if @slug == "gemini"
            gemini if gemini.is_a?(Hash)
          end

          def input_tokens(tokens, usage)
            input = usage["inputTokens"] || tokens.input
            @slug == "anthropic" ? [input, usage["input_tokens"]].compact.max : input
          end

          def output_tokens(tokens, usage)
            output = tokens.output
            thinking = tokens.thinking.to_i
            input = (usage["input_tokens"] || usage["prompt_tokens"]).to_i
            output && usage["total_tokens"] == input + output + thinking ? output + thinking : output
          end

          def cache_writes(total)
            cache = cache_creation
            return [total.to_i, 0] unless cache.is_a?(Hash)

            five_minute = cache["ephemeral_5m_input_tokens"].to_i
            one_hour = cache["ephemeral_1h_input_tokens"].to_i
            [five_minute + [total.to_i - five_minute - one_hour, 0].max, one_hour]
          end

          def cache_creation
            usage = @body["usage"] || {}
            case @slug
            when "anthropic" then usage["cache_creation"]
            when "bedrock"
              Array(usage["cacheDetails"]).to_h { |d| ["ephemeral_#{d['ttl']}_input_tokens", d["inputTokens"]] }
            end
          end
        end
      end
    end
  end
end
