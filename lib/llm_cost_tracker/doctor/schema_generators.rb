# frozen_string_literal: true

require_relative "../generators/llm_cost_tracker/add_billing_generator"
require_relative "../generators/llm_cost_tracker/add_capture_dimensions_generator"
require_relative "../generators/llm_cost_tracker/add_token_usage_generator"

module LlmCostTracker
  class Doctor
    class SchemaGenerators
      FOUNDATION_GENERATOR = "bin/rails generate llm_cost_tracker:upgrade_schema_foundation"
      RENAMED_CACHE_WRITE_COLUMNS = {
        "cache_write_extended_input_tokens" => "cache_write_1h_input_tokens"
      }.freeze

      COLUMN_GENERATORS = {
        "event_id" => "bin/rails generate llm_cost_tracker:add_ingestion",
        "latency_ms" => "bin/rails generate llm_cost_tracker:add_latency_ms",
        "stream" => "bin/rails generate llm_cost_tracker:add_streaming",
        "usage_source" => "bin/rails generate llm_cost_tracker:add_streaming",
        "provider_response_id" => "bin/rails generate llm_cost_tracker:add_provider_response_id"
      }.merge(
        Generators::AddBillingGenerator::COLUMN_NAMES.to_h do |column|
          [column, "bin/rails generate llm_cost_tracker:add_billing"]
        end
      ).merge(
        Generators::AddCaptureDimensionsGenerator::COLUMN_NAMES.to_h do |column|
          [column, "bin/rails generate llm_cost_tracker:add_capture_dimensions"]
        end
      ).merge(
        Generators::AddTokenUsageGenerator::COLUMN_NAMES.to_h do |column|
          [column, "bin/rails generate llm_cost_tracker:add_token_usage"]
        end
      ).freeze

      def self.for_missing_columns(missing, columns:)
        new(columns).for_missing_columns(missing)
      end

      def initialize(columns)
        @columns = columns
      end

      def for_missing_columns(missing)
        missing.filter_map { |column| generator_for(column) }.uniq
      end

      private

      attr_reader :columns

      def generator_for(column)
        legacy_column = RENAMED_CACHE_WRITE_COLUMNS[column]
        return FOUNDATION_GENERATOR if legacy_column && columns.key?(legacy_column)

        COLUMN_GENERATORS[column]
      end
    end
  end
end
