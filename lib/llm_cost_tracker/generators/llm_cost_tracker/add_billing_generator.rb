# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module LlmCostTracker
  module Generators
    class AddBillingGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      COLUMN_NAMES = %w[cost_status pricing_snapshot].freeze

      source_root File.expand_path("templates", __dir__)

      desc "Creates a migration to add billing audit columns and service charges"

      def create_migration_file
        migration_template(
          "add_billing_to_llm_cost_tracker.rb.erb",
          "db/migrate/add_billing_to_llm_cost_tracker.rb"
        )
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
