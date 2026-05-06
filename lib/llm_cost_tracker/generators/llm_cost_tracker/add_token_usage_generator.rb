# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

require_relative "../../billing/components"
require_relative "../../token_usage"

module LlmCostTracker
  module Generators
    class AddTokenUsageGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      INITIAL_TOKEN_COLUMNS = %i[input_tokens output_tokens total_tokens].freeze
      TOKEN_COLUMNS = (TokenUsage.members - INITIAL_TOKEN_COLUMNS).map(&:name).freeze
      COLUMN_NAMES = (TOKEN_COLUMNS + %w[pricing_mode]).freeze
      private_constant :INITIAL_TOKEN_COLUMNS

      source_root File.expand_path("templates", __dir__)

      desc "Creates a migration to add token usage and token cost columns to llm_cost_tracker_calls"

      def create_migration_file
        migration_template(
          "add_token_usage_to_llm_cost_tracker_calls.rb.erb",
          "db/migrate/add_token_usage_to_llm_cost_tracker_calls.rb"
        )
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
