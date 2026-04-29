# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module LlmCostTracker
  module Generators
    class AddIngestionGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Creates a migration to add durable ActiveRecord ingestion"

      def create_migration_file
        migration_template(
          "add_ingestion_to_llm_cost_tracker.rb.erb",
          "db/migrate/add_ingestion_to_llm_cost_tracker.rb"
        )
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
