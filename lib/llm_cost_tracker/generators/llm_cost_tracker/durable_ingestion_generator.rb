# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module LlmCostTracker
  module Generators
    class DurableIngestionGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Creates the durable ingestion tables (llm_cost_tracker_ingestion_inbox_entries + _leases). " \
           "Required when config.ingestion_adapter = :durable."

      def create_migration_file
        migration_template(
          "create_llm_cost_tracker_durable_ingestion.rb.erb",
          "db/migrate/create_llm_cost_tracker_durable_ingestion.rb"
        )
      end

      def warn_about_config_flag
        say(<<~MSG, :yellow)
          After migrating, set the following in config/initializers/llm_cost_tracker.rb:

            LlmCostTracker.configure do |config|
              config.ingestion_adapter = :durable
            end

          Without it the durable inbox tables stay unused and Tracker keeps writing
          inline. The doctor check warns about unused durable tables.
        MSG
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
