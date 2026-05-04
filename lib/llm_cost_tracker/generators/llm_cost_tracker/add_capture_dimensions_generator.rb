# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module LlmCostTracker
  module Generators
    class AddCaptureDimensionsGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      COLUMN_NAMES = %w[provider_project_id provider_api_key_id provider_workspace_id batch].freeze

      source_root File.expand_path("templates", __dir__)

      desc "Creates a migration to add provider capture dimensions"

      def create_migration_file
        migration_template(
          "add_capture_dimensions_to_llm_cost_tracker_calls.rb.erb",
          "db/migrate/add_capture_dimensions_to_llm_cost_tracker_calls.rb"
        )
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
