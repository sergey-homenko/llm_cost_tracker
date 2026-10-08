# frozen_string_literal: true

module LlmCostTracker
  module Providers
    module Gemini
      module UsageExtractor
        class << self
          def token_usage(usage)
            Usage::TokenUsage.build(
              **input_counts(usage),
              **output_counts(usage),
              total_tokens: usage["totalTokenCount"],
              hidden_output_tokens: usage["thoughtsTokenCount"]
            )
          end

          def line_items(usage)
            {
              "audio_cache_read_input" => modality_tokens(usage["cacheTokensDetails"], "AUDIO"),
              "video_output" => modality_tokens(usage["candidatesTokensDetails"], "VIDEO")
            }.filter_map do |dimension_key, quantity|
              Charges::LineItem.build(dimension_key: dimension_key, quantity: quantity) if quantity.positive?
            end
          end

          def from_interaction(usage, service_tier)
            {
              "promptTokenCount" => usage["total_input_tokens"],
              "cachedContentTokenCount" => usage["total_cached_tokens"],
              "toolUsePromptTokenCount" => usage["total_tool_use_tokens"],
              "candidatesTokenCount" => usage["total_output_tokens"],
              "thoughtsTokenCount" => usage["total_thought_tokens"],
              "totalTokenCount" => usage["total_tokens"],
              "promptTokensDetails" => interaction_modalities(usage["input_tokens_by_modality"]),
              "cacheTokensDetails" => interaction_modalities(usage["cached_tokens_by_modality"]),
              "candidatesTokensDetails" => interaction_modalities(usage["output_tokens_by_modality"]),
              "serviceTier" => service_tier
            }
          end

          def modality_tokens(details, modality)
            Array(details).sum do |detail|
              next 0 unless detail["modality"] == modality

              detail["tokenCount"].to_i
            end
          end

          private

          def input_counts(usage)
            cache_read = usage["cachedContentTokenCount"].to_i
            audio = uncached_prompt_tokens(usage, "AUDIO")
            image = uncached_prompt_tokens(usage, "IMAGE") + uncached_prompt_tokens(usage, "DOCUMENT")
            text = [usage["promptTokenCount"].to_i - cache_read - audio - image, 0].max
            {
              input_tokens: text + usage["toolUsePromptTokenCount"].to_i,
              cache_read_input_tokens: cache_read,
              audio_input_tokens: audio,
              image_input_tokens: image
            }
          end

          def output_counts(usage)
            audio = modality_tokens(usage["candidatesTokensDetails"], "AUDIO")
            image = modality_tokens(usage["candidatesTokensDetails"], "IMAGE")
            gross = usage["candidatesTokenCount"].to_i + usage["thoughtsTokenCount"].to_i
            { output_tokens: [gross - audio - image, 0].max, audio_output_tokens: audio, image_output_tokens: image }
          end

          def uncached_prompt_tokens(usage, modality)
            prompt = modality_tokens(usage["promptTokensDetails"] || usage["promptTokenDetails"], modality)
            cached = modality_tokens(usage["cacheTokensDetails"], modality)
            [prompt - cached, 0].max
          end

          def interaction_modalities(entries)
            Array(entries).map do |entry|
              { "modality" => entry["modality"].to_s.upcase, "tokenCount" => entry["tokens"] }
            end
          end
        end
      end
    end
  end
end
