# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module LlmCostTracker
  module Generators
    class UpgradeCallIndexesGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Replaces the unused (provider, tracked_at) and (model, tracked_at) indexes on " \
           "llm_cost_tracker_calls with a partial index over unpriced rows, so " \
           "llm_cost_tracker:backfill_unknown_pricing stops scanning the whole table."

      def create_migration_file
        migration_template(
          "upgrade_call_indexes.rb.erb",
          "db/migrate/upgrade_llm_cost_tracker_call_indexes.rb"
        )
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
