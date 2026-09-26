# frozen_string_literal: true

module LlmCostTracker
  module Providers
    module Gemini
      module UsageExtractor
        def self.token_usage(usage)
          cache_read = usage["cachedContentTokenCount"].to_i
          tool_use_prompt = usage["toolUsePromptTokenCount"].to_i
          audio_input = uncached_prompt_tokens(usage, "AUDIO")
          audio_output = modality_tokens(usage["candidatesTokensDetails"], "AUDIO")
          image_input = uncached_prompt_tokens(usage, "IMAGE")
          image_output = modality_tokens(usage["candidatesTokensDetails"], "IMAGE")

          Usage::TokenUsage.build(
            input_tokens: regular_input_tokens(usage: usage,
                                               cache_read: cache_read,
                                               audio_input: audio_input,
                                               image_input: image_input) +
                          tool_use_prompt,
            output_tokens: regular_output_tokens(usage: usage,
                                                 audio_output: audio_output,
                                                 image_output: image_output),
            total_tokens: usage["totalTokenCount"],
            cache_read_input_tokens: cache_read,
            audio_input_tokens: audio_input,
            audio_output_tokens: audio_output,
            image_input_tokens: image_input,
            image_output_tokens: image_output,
            hidden_output_tokens: usage["thoughtsTokenCount"]
          )
        end

        def self.gross_output_tokens(usage)
          usage["candidatesTokenCount"].to_i + usage["thoughtsTokenCount"].to_i
        end

        def self.regular_input_tokens(usage:, cache_read:, audio_input:, image_input:)
          [usage["promptTokenCount"].to_i - cache_read - audio_input - image_input, 0].max
        end

        def self.regular_output_tokens(usage:, audio_output:, image_output:)
          [gross_output_tokens(usage) - audio_output - image_output, 0].max
        end

        def self.uncached_prompt_tokens(usage, modality)
          prompt = modality_tokens(usage["promptTokensDetails"], modality)
          cached = modality_tokens(usage["cacheTokensDetails"], modality)
          [prompt - cached, 0].max
        end

        def self.modality_tokens(details, modality)
          Array(details).sum do |detail|
            next 0 unless detail["modality"] == modality

            detail["tokenCount"].to_i
          end
        end
      end
    end
  end
end
