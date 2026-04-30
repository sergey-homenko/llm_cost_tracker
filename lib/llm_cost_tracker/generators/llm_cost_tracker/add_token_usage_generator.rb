# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"
require "llm_cost_tracker/token_usage"
require "llm_cost_tracker/pricing/cost"

module LlmCostTracker
  module Generators
    class AddTokenUsageGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

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
