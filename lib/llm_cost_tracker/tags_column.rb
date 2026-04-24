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

    def stream_column?
      columns_hash.key?("stream")
    end

    def usage_source_column?
      columns_hash.key?("usage_source")
    end

    def provider_response_id_column?
      columns_hash.key?("provider_response_id")
    end

    def pricing_mode_column?
      columns_hash.key?("pricing_mode")
    end

    def usage_breakdown_columns?
      %w[
        cache_read_input_tokens
        cache_write_input_tokens
        hidden_output_tokens
      ].all? { |column| columns_hash.key?(column) }
    end

    def usage_breakdown_cost_columns?
      %w[
        cache_read_input_cost
        cache_write_input_cost
      ].all? { |column| columns_hash.key?(column) }
    end
  end
end
