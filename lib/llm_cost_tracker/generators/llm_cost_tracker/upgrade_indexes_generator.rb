# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module LlmCostTracker
  module Generators
    class UpgradeIndexesGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Adds a partial index over unpriced calls and drops the unused ingestion inbox lock index" \
           "scanning the whole ledger."

      def create_migration_file
        migration_template(
          "upgrade_indexes.rb.erb",
          "db/migrate/upgrade_llm_cost_tracker_indexes.rb"
        )
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
