# frozen_string_literal: true

module LlmCostTracker
  module TagsColumn
    def tags_json_column?
      column = columns_hash["tags"]
      return false unless column

      %i[json jsonb].include?(column.type) || column.sql_type.to_s.downcase == "jsonb"
    end

    def latency_column?
      columns_hash.key?("latency_ms")
    end
  end
end
