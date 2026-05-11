# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module LlmCostTracker
  module Generators
    class UpgradeImageTokensGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Adds image_input_tokens and image_output_tokens columns to llm_cost_tracker_calls."

      def create_migration_file
        migration_template(
          "upgrade_image_tokens.rb.erb",
          "db/migrate/upgrade_llm_cost_tracker_image_tokens.rb"
        )
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
