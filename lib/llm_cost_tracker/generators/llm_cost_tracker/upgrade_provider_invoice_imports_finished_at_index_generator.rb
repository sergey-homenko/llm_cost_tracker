# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module LlmCostTracker
  module Generators
    class UpgradeProviderInvoiceImportsFinishedAtIndexGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Adds a (state, finished_at) index on llm_cost_tracker_provider_invoice_imports so " \
           "Retention.prune_invoice_imports can find completed/failed rows past the cutoff " \
           "without a sequential scan."

      def create_migration_file
        migration_template(
          "upgrade_provider_invoice_imports_finished_at_index.rb.erb",
          "db/migrate/upgrade_llm_cost_tracker_provider_invoice_imports_finished_at_index.rb"
        )
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
