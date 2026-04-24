# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module LlmCostTracker
  module Generators
    class AddDailyTotalsGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Creates a migration to add llm_cost_tracker_daily_totals"

      def create_migration_file
        migration_template(
          "add_daily_totals_to_llm_cost_tracker.rb.erb",
          "db/migrate/add_daily_totals_to_llm_cost_tracker.rb"
        )
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
