# frozen_string_literal: true

require "json"

module LlmCostTracker
  module TagQuery
    class << self
      def apply(model, tags)
        normalized_tags = (tags || {}).to_h.transform_keys(&:to_s).transform_values(&:to_s)
        return model.all if normalized_tags.empty?

        return model.where("tags @> ?::jsonb", normalized_tags.to_json) if model.tags_jsonb_column?
        return model.where("JSON_CONTAINS(tags, ?)", normalized_tags.to_json) if model.tags_mysql_json_column?

        text_query(model, normalized_tags)
      end

      private

      def text_query(model, tags)
        tags.reduce(model.all) do |relation, (key, value)|
          fragment = JSON.generate(key => value).delete_prefix("{").delete_suffix("}")
          relation.where("tags LIKE ? ESCAPE '\\'", "%#{model.sanitize_sql_like(fragment)}%")
        end
      end
    end
  end
end
