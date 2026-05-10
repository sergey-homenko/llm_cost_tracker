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

      def warn_about_dedup
        say(<<~MSG, :yellow)
          The new (period, period_start, currency, provider) unique index will fail to apply
          if your call_rollups table already has duplicate rows under the old constraint.
          See docs/upgrading.md for the dedupe SQL snippet to run before the migration.
        MSG
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
