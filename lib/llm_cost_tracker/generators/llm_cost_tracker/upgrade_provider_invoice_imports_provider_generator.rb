# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module LlmCostTracker
  module Generators
    class UpgradeProviderInvoiceImportsProviderGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Adds a provider column to llm_cost_tracker_provider_invoice_imports and a " \
           "(source, provider, started_at) index so resume_cursor_for and " \
           "last_completed_window_for can isolate per-provider state on shared sources (e.g. csv)."

      def create_migration_file
        migration_template(
          "upgrade_provider_invoice_imports_provider.rb.erb",
          "db/migrate/upgrade_llm_cost_tracker_provider_invoice_imports_provider.rb"
        )
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
