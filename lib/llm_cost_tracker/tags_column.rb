# frozen_string_literal: true

require_relative "active_record_adapter"
require_relative "cost"
require_relative "token_usage"

module LlmCostTracker
  module TagsColumn
    TOKEN_USAGE_COLUMNS = TokenUsage::OPTIONAL_STORED_KEYS.map(&:to_s).freeze
    TOKEN_USAGE_COST_COLUMNS = Cost::OPTIONAL_STORED_KEYS.map(&:to_s).freeze

    def reset_column_information
      remove_instance_variable(:@lct_schema_capabilities) if instance_variable_defined?(:@lct_schema_capabilities)

      super
    end

    def tags_json_column?
      capabilities = lct_schema_capabilities

      capabilities.fetch(:tags_jsonb) || capabilities.fetch(:tags_mysql_json)
    end

    def tags_jsonb_column?
      lct_schema_capabilities.fetch(:tags_jsonb)
    end

    def tags_mysql_json_column?
      lct_schema_capabilities.fetch(:tags_mysql_json)
    end

    def latency_column?
      lct_schema_capabilities.fetch(:latency)
    end

    def stream_column?
      lct_schema_capabilities.fetch(:stream)
    end

    def usage_source_column?
      lct_schema_capabilities.fetch(:usage_source)
    end

    def provider_response_id_column?
      lct_schema_capabilities.fetch(:provider_response_id)
    end

    def pricing_mode_column?
      lct_schema_capabilities.fetch(:pricing_mode)
    end

    def token_usage_columns?
      lct_schema_capabilities.fetch(:token_usage)
    end

    def token_usage_cost_columns?
      lct_schema_capabilities.fetch(:token_usage_cost)
    end

    private

    def lct_schema_capabilities
      columns = columns_hash
      adapter_name = connection.adapter_name
      cache = @lct_schema_capabilities

      return cache.fetch(:values) if cache && cache.fetch(:columns).equal?(columns) &&
                                     cache.fetch(:adapter_name) == adapter_name

      values = build_lct_schema_capabilities(columns, adapter_name)
      @lct_schema_capabilities = { columns: columns, adapter_name: adapter_name, values: values }
      values
    end

    def build_lct_schema_capabilities(columns, adapter_name)
      ActiveRecordAdapter.ensure_supported!(adapter_name)

      tag_column = columns["tags"]
      tags_jsonb = tag_column && (tag_column.type == :jsonb || tag_column.sql_type.to_s.downcase == "jsonb")
      tags_mysql_json =
        tag_column &&
        !tags_jsonb &&
        tag_column.type == :json &&
        ActiveRecordAdapter.mysql?(adapter_name)

      {
        tags_jsonb: tags_jsonb ? true : false,
        tags_mysql_json: tags_mysql_json ? true : false,
        latency: columns.key?("latency_ms"),
        stream: columns.key?("stream"),
        usage_source: columns.key?("usage_source"),
        provider_response_id: columns.key?("provider_response_id"),
        pricing_mode: columns.key?("pricing_mode"),
        token_usage: TOKEN_USAGE_COLUMNS.all? { |column| columns.key?(column) },
        token_usage_cost: TOKEN_USAGE_COST_COLUMNS.all? { |column| columns.key?(column) }
      }
    end
  end
end
