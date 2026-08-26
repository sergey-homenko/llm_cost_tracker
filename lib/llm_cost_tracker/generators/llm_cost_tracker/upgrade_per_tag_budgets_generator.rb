# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module LlmCostTracker
  module Generators
    class UpgradePerTagBudgetsGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Carries each call's cost and time onto its tag rows so per-tag budgets read " \
           "llm_cost_tracker_call_tags without a join. Required when config.budgets.per_tag is set."

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
