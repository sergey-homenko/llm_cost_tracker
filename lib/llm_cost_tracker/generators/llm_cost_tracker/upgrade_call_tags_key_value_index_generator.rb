# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module LlmCostTracker
  module Generators
    class UpgradeCallTagsKeyValueIndexGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Adds a (key, value) composite index on llm_cost_tracker_call_tags " \
           "so high-cardinality tag filters use an index lookup instead of a key-only scan."

      def create_migration_file
        migration_template(
          "upgrade_call_tags_key_value_index.rb.erb",
          "db/migrate/upgrade_llm_cost_tracker_call_tags_key_value_index.rb"
        )
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
