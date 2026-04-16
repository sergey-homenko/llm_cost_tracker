# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module LlmCostTracker
  module Generators
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Creates the LlmCostTracker migration and initializer"

      def create_migration_file
        migration_template(
          "create_llm_api_calls.rb.erb",
          "db/migrate/create_llm_api_calls.rb"
        )
      end

      def create_initializer
        template(
          "initializer.rb.erb",
          "config/initializers/llm_cost_tracker.rb"
        )
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
