# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module LlmCostTracker
  module Generators
    class UpgradeCallLineItemsCurrencyIndexGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Adds a (llm_cost_tracker_call_id, currency) composite index on " \
           "llm_cost_tracker_call_line_items so Reconciliation::Diff EXISTS subqueries " \
           "hit an index instead of a per-row sequential scan."

      def create_migration_file
        migration_template(
          "upgrade_call_line_items_currency_index.rb.erb",
          "db/migrate/upgrade_llm_cost_tracker_call_line_items_currency_index.rb"
        )
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
