# frozen_string_literal: true

require_relative "model_families"

module LlmCostTracker
  module Providers
    module Openai
      module UsageExtractor
        INPUT_DETAIL_KEYS = %i[input_tokens_details input_token_details prompt_tokens_details].freeze
        OUTPUT_DETAIL_KEYS = %i[output_tokens_details output_token_details completion_tokens_details].freeze
        def self.token_usage(usage, model: nil)
          output_tokens = (usage[:output_tokens] || usage[:completion_tokens]).to_i
          audio_output = audio_output_tokens(usage)
          image_output, regular_output = split_output(
            output_tokens: output_tokens,
            image_output_details: image_output_tokens(usage),
            text_output_details: text_output_tokens(usage),
            audio_output: audio_output,
            default_to_image: ModelFamilies.image_output?(model)
          )

          Usage::TokenUsage.build(
            **input_buckets(usage),
            output_tokens: regular_output,
            total_tokens: usage[:total_tokens],
            audio_output_tokens: audio_output,
            image_output_tokens: image_output,
            hidden_output_tokens: hidden_output_tokens(usage)
          )
        end

        def self.input_buckets(usage)
          input_tokens = (usage[:input_tokens] || usage[:prompt_tokens]).to_i
          cached = cache_read_input_tokens(usage) + cache_write_input_tokens(usage)
          audio_input = uncached_input_tokens(usage, :audio_tokens)
          image_input = uncached_input_tokens(usage, :image_tokens)
          overlap = input_tokens.positive? ? [cached + audio_input + image_input - input_tokens, 0].max : 0
          audio_overlap = [overlap, audio_input].min
          audio_input -= audio_overlap
          image_input -= [overlap - audio_overlap, image_input].min

          {
            input_tokens: [input_tokens - cached - audio_input - image_input, 0].max,
            cache_read_input_tokens: cache_read_input_tokens(usage),
            cache_write_input_tokens: cache_write_input_tokens(usage),
            audio_input_tokens: audio_input,
            image_input_tokens: image_input
          }
        end

        def self.uncached_input_tokens(usage, key)
          [detail(usage, INPUT_DETAIL_KEYS, key) - detail(usage, INPUT_DETAIL_KEYS, :cached_tokens_details, key), 0].max
        end

        def self.split_output(output_tokens:,
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

        def self.cache_read_input_tokens(usage) = detail(usage, INPUT_DETAIL_KEYS, :cached_tokens)
        def self.cache_write_input_tokens(usage) = detail(usage, INPUT_DETAIL_KEYS, :cache_write_tokens)
        def self.hidden_output_tokens(usage)    = detail(usage, OUTPUT_DETAIL_KEYS, :reasoning_tokens)
        def self.audio_input_tokens(usage)      = detail(usage, INPUT_DETAIL_KEYS, :audio_tokens)
        def self.audio_output_tokens(usage)     = detail(usage, OUTPUT_DETAIL_KEYS, :audio_tokens)
        def self.image_input_tokens(usage)      = detail(usage, INPUT_DETAIL_KEYS, :image_tokens)
        def self.image_output_tokens(usage)     = detail(usage, OUTPUT_DETAIL_KEYS, :image_tokens)
        def self.text_output_tokens(usage)      = detail(usage, OUTPUT_DETAIL_KEYS, :text_tokens)

        def self.detail(usage, containers, *path)
          containers.each do |container|
            value = usage.dig(container, *path)
            return value.to_i if value
          end
          0
        end
      end
    end
  end
end
