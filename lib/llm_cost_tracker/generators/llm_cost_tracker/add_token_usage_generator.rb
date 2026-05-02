# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module LlmCostTracker
  module Generators
    class AddTokenUsageGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      TOKEN_COLUMNS = %w[
        cache_read_input_tokens
        cache_write_input_tokens
        cache_write_1h_input_tokens
        audio_input_tokens
        audio_output_tokens
        hidden_output_tokens
      ].freeze
      COST_COLUMNS = %w[
        cache_read_input_cost
        cache_write_input_cost
        cache_write_1h_input_cost
        audio_input_cost
        audio_output_cost
      ].freeze
      COLUMN_NAMES = (TOKEN_COLUMNS + COST_COLUMNS + %w[pricing_mode]).freeze

      source_root File.expand_path("templates", __dir__)

      desc "Creates a migration to add token usage and token cost columns to llm_api_calls"

      def create_migration_file
        migration_template(
          "add_token_usage_to_llm_api_calls.rb.erb",
          "db/migrate/add_token_usage_to_llm_api_calls.rb"
        )
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
