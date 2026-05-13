# frozen_string_literal: true

module LlmCostTracker
  module Providers
    module Gemini
      module ModelFamilies
        PER_QUERY_GROUNDING_MODEL_PATTERN = /\bgemini-(?:[3-9]|[1-9]\d)\b/i

        module_function

        def per_query_grounding?(model)
          model.to_s.match?(PER_QUERY_GROUNDING_MODEL_PATTERN)
        end
      end
    end
  end
end
