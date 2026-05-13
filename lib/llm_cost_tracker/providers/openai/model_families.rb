# frozen_string_literal: true

module LlmCostTracker
  module Providers
    module Openai
      module ModelFamilies
        DATA_RESIDENCY_MODEL_PATTERN =
          /\Agpt-5\.(?:4|5)(?:-(?:mini|nano|pro|codex(?:-mini|-max)?))?(?:-\d{4}-\d{2}-\d{2})?\z/

        IMAGE_OUTPUT_MODEL_PATTERN = /\Agpt-image-/i

        CHARACTER_BILLED_TTS_MODEL_PATTERN = /\Atts-1(-hd)?\z/

        REASONING_MODEL_PATTERNS = [
          /\Agpt-5(\b|[\d.-])/i,
          /\Ao\d+(\b|[\d.-])/i
        ].freeze

        NON_REASONING_GPT5_PATTERN = /\Agpt-5(?:\.\d+)?-chat\b/i

        module_function

        def data_residency?(model)
          model.to_s.match?(DATA_RESIDENCY_MODEL_PATTERN)
        end

        def image_output?(model)
          model.to_s.match?(IMAGE_OUTPUT_MODEL_PATTERN)
        end

        def character_billed_tts?(model)
          model.to_s.match?(CHARACTER_BILLED_TTS_MODEL_PATTERN)
        end

        def reasoning?(model)
          name = model.to_s
          return false if name.empty?
          return false if NON_REASONING_GPT5_PATTERN.match?(name)

          REASONING_MODEL_PATTERNS.any? { |pattern| pattern.match?(name) }
        end
      end
    end
  end
end
