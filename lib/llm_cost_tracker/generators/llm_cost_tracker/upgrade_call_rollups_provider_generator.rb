# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module LlmCostTracker
  module Generators
    class UpgradeCallRollupsProviderGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Adds the v0.9 provider column and unique index to llm_cost_tracker_call_rollups."

      def create_migration_file
        migration_template(
          "upgrade_call_rollups_provider.rb.erb",
          "db/migrate/upgrade_llm_cost_tracker_call_rollups_provider.rb"
        )
      end

      def warn_about_rollups_truncation
        say(<<~MSG, :yellow)
          The migration clears existing llm_cost_tracker_call_rollups rows before adding the
          provider column. Budget reads fall back to live aggregation from
          llm_cost_tracker_calls until new events repopulate the rollups under their provider
          keys. See docs/upgrading.md for details.
        MSG
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
