# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module LlmCostTracker
  module Generators
    class UpgradeTagsToJsonbGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Creates a migration to upgrade llm_api_calls.tags to PostgreSQL JSONB"

      def create_migration_file
        migration_template(
          "upgrade_llm_api_call_tags_to_jsonb.rb.erb",
          "db/migrate/upgrade_llm_api_call_tags_to_jsonb.rb"
        )
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
