# frozen_string_literal: true

module LlmCostTracker
  module Providers
    module Openai
      module ModelFamilies
        IMAGE_OUTPUT_MODEL_PATTERN = /\Agpt-image-/i

        CHARACTER_BILLED_TTS_MODEL_PATTERN = /\Atts-1(-hd)?\z/

        REASONING_MODEL_PATTERNS = [
          /\Agpt-5(\b|[\d.-])/i,
          /\Ao\d+(\b|[\d.-])/i
        ].freeze

        NON_REASONING_GPT5_PATTERN = /\Agpt-5(?:\.\d+)?-chat\b/i

        CHAT_COMPLETIONS_SEARCH_MODEL_PATTERN = /-search-(?:preview|api)\b/i
        def self.image_output?(model)
          model.to_s.match?(IMAGE_OUTPUT_MODEL_PATTERN)
        end

        def self.character_billed_tts?(model)
          model.to_s.match?(CHARACTER_BILLED_TTS_MODEL_PATTERN)
        end

        def self.chat_completions_search?(model)
          model.to_s.match?(CHAT_COMPLETIONS_SEARCH_MODEL_PATTERN)
        end

        def self.reasoning?(model)
          name = model.to_s
          return false if name.empty?
          return false if NON_REASONING_GPT5_PATTERN.match?(name)

          REASONING_MODEL_PATTERNS.any? { |pattern| pattern.match?(name) }
        end
      end
    end
  end
end
