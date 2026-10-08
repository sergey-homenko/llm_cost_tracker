# frozen_string_literal: true

require_relative "model_families"

module LlmCostTracker
  module Providers
    module Openai
      module UsageExtractor
        INPUT_DETAIL_KEYS = %i[input_tokens_details input_token_details prompt_tokens_details].freeze
        OUTPUT_DETAIL_KEYS = %i[output_tokens_details output_token_details completion_tokens_details].freeze
        CACHED_MODALITY_DIMENSIONS = {
          audio_tokens: "audio_cache_read_input", image_tokens: "image_cache_read_input"
        }.freeze

        class << self
          def token_usage(usage, model: nil, default_to_image: ModelFamilies.image_output?(model))
            cache_read = cache_read_input_tokens(usage)
            cache_write = cache_write_input_tokens(usage)
            Usage::TokenUsage.build(
              **input_counts(usage, cached: cache_read + cache_write),
              **output_counts(usage, default_to_image: default_to_image),
              total_tokens: usage[:total_tokens],
              cache_read_input_tokens: cache_read,
              cache_write_input_tokens: cache_write,
              hidden_output_tokens: hidden_output_tokens(usage)
            )
          end

          def cache_read_line_items(usage)
            CACHED_MODALITY_DIMENSIONS.filter_map do |detail_key, dimension_key|
              quantity = detail(usage, INPUT_DETAIL_KEYS, :cached_tokens_details, detail_key)
              Charges::LineItem.build(dimension_key: dimension_key, quantity: quantity) if quantity.positive?
            end
          end

          def split_output(output_tokens:,
                           image_output_details:,
                           text_output_details:,
                           audio_output:,
                           default_to_image: false)
            if image_output_details.zero? && text_output_details.zero?
              remainder = [output_tokens - audio_output, 0].max
              return default_to_image ? [remainder, 0] : [0, remainder]
            end

            [image_output_details, [output_tokens - image_output_details - audio_output, 0].max]
          end

          def cache_read_input_tokens(usage) = detail(usage, INPUT_DETAIL_KEYS, :cached_tokens)
          def cache_write_input_tokens(usage) = detail(usage, INPUT_DETAIL_KEYS, :cache_write_tokens)
          def hidden_output_tokens(usage)    = detail(usage, OUTPUT_DETAIL_KEYS, :reasoning_tokens)
          def audio_input_tokens(usage)      = detail(usage, INPUT_DETAIL_KEYS, :audio_tokens)
          def audio_output_tokens(usage)     = detail(usage, OUTPUT_DETAIL_KEYS, :audio_tokens)
          def image_input_tokens(usage)      = detail(usage, INPUT_DETAIL_KEYS, :image_tokens)
          def image_output_tokens(usage)     = detail(usage, OUTPUT_DETAIL_KEYS, :image_tokens)
          def text_output_tokens(usage)      = detail(usage, OUTPUT_DETAIL_KEYS, :text_tokens)

          def uncached_input_tokens(usage, key)
            detail(usage, INPUT_DETAIL_KEYS, key) - detail(usage, INPUT_DETAIL_KEYS, :cached_tokens_details, key)
          end

          def detail(usage, containers, *path)
            containers.each do |container|
              value = usage.dig(container, *path)
              return value.to_i if value
            end
            0
          end

          private

          def input_counts(usage, cached:)
            uncached = [prompt_tokens(usage) - cached, 0].max
            image = uncached_input_tokens(usage, :image_tokens).clamp(0, uncached)
            audio = uncached_input_tokens(usage, :audio_tokens).clamp(0, uncached - image)
            { input_tokens: uncached - audio - image, image_input_tokens: image, audio_input_tokens: audio }
          end

          def output_counts(usage, default_to_image:)
            output = (usage[:output_tokens] || usage[:completion_tokens]).to_i
            reasoning = hidden_output_tokens(usage)
            output += reasoning if usage[:total_tokens].to_i == prompt_tokens(usage) + output + reasoning
            audio = audio_output_tokens(usage)
            image, regular = split_output(
              output_tokens: output,
              image_output_details: image_output_tokens(usage),
              text_output_details: text_output_tokens(usage),
              audio_output: audio,
              default_to_image: default_to_image
            )
            { output_tokens: regular, image_output_tokens: image, audio_output_tokens: audio }
          end

          def prompt_tokens(usage)
            (usage[:input_tokens] || usage[:prompt_tokens]).to_i
          end
        end
      end
    end
  end
end
