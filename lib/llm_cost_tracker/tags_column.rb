# frozen_string_literal: true

module LlmCostTracker
  module TagsColumn
    def tags_json_column?
      tags_jsonb_column? || tags_mysql_json_column?
    end

    def tags_jsonb_column?
      column = columns_hash["tags"]
      return false unless column

      column.type == :jsonb || column.sql_type.to_s.downcase == "jsonb"
    end

    def tags_mysql_json_column?
      column = columns_hash["tags"]
      return false unless column
      return false if tags_jsonb_column?

      column.type == :json && connection.adapter_name.match?(/mysql/i)
    end

    def latency_column?
      columns_hash.key?("latency_ms")
    end
  end
end
