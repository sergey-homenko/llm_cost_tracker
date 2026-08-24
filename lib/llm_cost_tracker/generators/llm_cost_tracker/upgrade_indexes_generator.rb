# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module LlmCostTracker
  module Generators
    class UpgradeIndexesGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Drops three indexes the query planner never chooses and adds a partial index " \
           "over unpriced calls, so llm_cost_tracker:backfill_unknown_pricing stops " \
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
