# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module LlmCostTracker
  module Generators
    class UpgradeIndexesGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Adds the unpriced-calls index (partial on PostgreSQL, so backfill_unknown_pricing stops scanning " \
           "the whole ledger; a plain id index on MySQL, which has no partial indexes) and drops the unused " \
           "ingestion inbox lock index."

      def create_migration_file
        migration_template(
          "upgrade_indexes.rb.erb",
          "db/migrate/upgrade_llm_cost_tracker_indexes.rb"
        )
      end
    end
  end
end
