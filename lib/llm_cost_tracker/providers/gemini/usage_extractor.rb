# frozen_string_literal: true

module LlmCostTracker
  module Providers
    module Gemini
      module UsageExtractor
        def self.token_usage(usage)
          cache_read = usage["cachedContentTokenCount"].to_i
          tool_use_prompt = usage["toolUsePromptTokenCount"].to_i
          audio_input = audio_input_tokens(usage)
          audio_output = audio_output_tokens(usage)
          image_input = image_input_tokens(usage)
          image_output = image_output_tokens(usage)

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

        def self.audio_input_tokens(usage)
          prompt_audio = modality_tokens(usage["promptTokensDetails"], "AUDIO")
          cache_audio = modality_tokens(usage["cacheTokensDetails"], "AUDIO")
          [prompt_audio - cache_audio, 0].max
        end

        def self.audio_output_tokens(usage)
          modality_tokens(usage["candidatesTokensDetails"], "AUDIO")
        end

        def self.image_input_tokens(usage)
          prompt_image = modality_tokens(usage["promptTokensDetails"], "IMAGE")
          cache_image = modality_tokens(usage["cacheTokensDetails"], "IMAGE")
          [prompt_image - cache_image, 0].max
        end

        def self.image_output_tokens(usage)
          modality_tokens(usage["candidatesTokensDetails"], "IMAGE")
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
