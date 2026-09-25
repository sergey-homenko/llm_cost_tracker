# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module LlmCostTracker
  module Generators
    class UpgradePerTagBudgetsGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Adds cost and time columns to llm_cost_tracker_call_tags so per-tag budgets read it " \
           "without a join; run llm_cost_tracker:backfill_tag_costs afterwards so earlier calls count. " \
           "Required for config.budgets.per_tag on installs created before v0.14."

      def create_migration_file
        migration_template(
          "upgrade_per_tag_budgets.rb.erb",
          "db/migrate/upgrade_llm_cost_tracker_per_tag_budgets.rb"
        )
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
