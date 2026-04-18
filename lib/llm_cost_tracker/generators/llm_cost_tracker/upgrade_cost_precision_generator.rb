# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module LlmCostTracker
  module Generators
    class UpgradeCostPrecisionGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Creates a migration to widen llm_api_calls cost decimal precision"

      def create_migration_file
        migration_template(
          "upgrade_llm_api_call_cost_precision.rb.erb",
          "db/migrate/upgrade_llm_api_call_cost_precision.rb"
        )
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
