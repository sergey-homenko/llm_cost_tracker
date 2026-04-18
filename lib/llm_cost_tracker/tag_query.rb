# frozen_string_literal: true

require "json"

module LlmCostTracker
  module TagQuery
    class << self
      def apply(model, tags)
        normalized_tags = normalize_tags(tags)
        return model.all if normalized_tags.empty?

        return json_query(model, normalized_tags) if model.tags_json_column?

        text_query(model, normalized_tags)
      end

      def normalize_tags(tags)
        (tags || {}).to_h.transform_keys(&:to_s).transform_values(&:to_s)
      end

      private

      def json_query(model, tags)
        model.where("tags @> ?::jsonb", tags.to_json)
      end

      def text_query(model, tags)
        tags.reduce(model.all) do |relation, (key, value)|
          relation.where("tags LIKE ? ESCAPE '\\'", "%#{model.sanitize_sql_like(json_tag_fragment(key, value))}%")
        end
      end

      def json_tag_fragment(key, value)
        JSON.generate(key => value).delete_prefix("{").delete_suffix("}")
      end
    end
  end
end
