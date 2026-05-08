# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module LlmCostTracker
  module Generators
    class ReconciliationGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Creates the optional invoice reconciliation tables. Requires provider admin/org-level API keys."

      def create_migration_file
        migration_template(
          "create_llm_cost_tracker_reconciliation.rb.erb",
          "db/migrate/create_llm_cost_tracker_reconciliation.rb"
        )
      end

      def warn_about_admin_keys
        say "Reconciliation requires admin/org-level API keys (OpenAI sk-admin-..., Anthropic admin keys, " \
            "GCP billing.viewer service accounts). Do NOT use the runtime inference key.", :yellow
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
