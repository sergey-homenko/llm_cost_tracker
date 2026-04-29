# frozen_string_literal: true

require "active_support/core_ext/object/blank"

require_relative "active_record_adapter"
require_relative "tag_key"

module LlmCostTracker
  module TagSql
    class << self
      def value_expression(model, key, table_name:)
        key = TagKey.validate!(key)
        column = "#{table_name}.#{model.connection.quote_column_name('tags')}"

        if ActiveRecordAdapter.postgresql?(model.connection)
          json_column = model.tags_jsonb_column? ? column : "(#{column})::jsonb"
          "#{json_column}->>#{model.connection.quote(key)}"
        elsif ActiveRecordAdapter.mysql?(model.connection)
          "JSON_UNQUOTE(JSON_EXTRACT(#{column}, #{model.connection.quote(json_path(key))}))"
        else
          ActiveRecordAdapter.ensure_supported!(model.connection)
        end
      end

      def value_label(value)
        value.to_s.presence || "(untagged)"
      end

      private

      def json_path(key)
        "$.\"#{key}\""
      end
    end
  end
end
