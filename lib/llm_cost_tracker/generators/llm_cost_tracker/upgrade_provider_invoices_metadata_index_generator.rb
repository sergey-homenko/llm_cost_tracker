# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module LlmCostTracker
  module Generators
    class UpgradeProviderInvoicesMetadataIndexGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Adds a GIN index on llm_cost_tracker_provider_invoices.metadata for PostgreSQL " \
           "so Reconciliation::Diff queries that filter on metadata->>'provider' / 'row_type' / " \
           "'match_basis' hit an index instead of a sequential scan. No-op on MySQL."

      def create_migration_file
        migration_template(
          "upgrade_provider_invoices_metadata_index.rb.erb",
          "db/migrate/upgrade_llm_cost_tracker_provider_invoices_metadata_index.rb"
        )
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
