# frozen_string_literal: true

require "json"

module LlmCostTracker
  class Ledger
    module Tags
      module Query
        class << self
          def apply(model, tags)
            normalized_tags = (tags || {}).to_h.transform_keys(&:to_s).transform_values(&:to_s)
            return model.all if normalized_tags.empty?

            return model.where("tags @> ?::jsonb", normalized_tags.to_json) if model.tags_jsonb_column?

            model.where("JSON_CONTAINS(tags, ?)", normalized_tags.to_json)
          end
        end
      end
    end
  end
end
