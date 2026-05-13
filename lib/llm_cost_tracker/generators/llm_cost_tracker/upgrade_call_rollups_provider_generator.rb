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

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
