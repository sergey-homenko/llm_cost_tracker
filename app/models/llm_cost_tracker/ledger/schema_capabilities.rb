# frozen_string_literal: true

require "llm_cost_tracker/ledger/database_adapter"
require "llm_cost_tracker/token_usage"

module LlmCostTracker
  module Ledger
    module SchemaCapabilities
      CURRENT_SCHEMA_COLUMNS = (
        %i[event_id provider model latency_ms stream usage_source provider_response_id pricing_mode tags tracked_at] +
        TokenUsage::STORED_KEYS +
        TokenUsage::STORED_COST_KEYS
      ).map(&:to_s).freeze

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

      def current_schema?
        current_schema_errors.empty?
      end

      def current_schema_errors
        lct_schema_capabilities.fetch(:current_schema_errors)
      end

      def missing_current_schema_columns
        lct_schema_capabilities.fetch(:missing_current_schema_columns)
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
        Ledger::DatabaseAdapter.ensure_supported!(adapter_name)

        tag_column = columns["tags"]
        tags_jsonb = tag_column && (tag_column.type == :jsonb || tag_column.sql_type.to_s.downcase == "jsonb")
        tags_mysql_json =
          tag_column &&
          !tags_jsonb &&
          tag_column.type == :json &&
          Ledger::DatabaseAdapter.mysql?(adapter_name)

        {
          tags_jsonb: tags_jsonb ? true : false,
          tags_mysql_json: tags_mysql_json ? true : false,
          missing_current_schema_columns: missing_columns_for(columns),
          current_schema_errors: schema_errors_for(columns, tags_jsonb, tags_mysql_json, adapter_name)
        }
      end

      def schema_errors_for(columns, tags_jsonb, tags_mysql_json, adapter_name)
        errors = []
        missing = missing_columns_for(columns)
        errors << "missing columns: #{missing.join(', ')}" if missing.any?

        if columns.key?("tags") && !tags_jsonb && !tags_mysql_json
          expected_type = Ledger::DatabaseAdapter.postgresql?(adapter_name) ? "jsonb" : "json"
          errors << "tags column must use #{expected_type}"
        end

        errors
      end

      def missing_columns_for(columns)
        CURRENT_SCHEMA_COLUMNS - columns.keys
      end
    end
  end
end
