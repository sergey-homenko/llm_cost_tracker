# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module LlmCostTracker
  module Generators
    class AsyncIngestionGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Creates the async ingestion tables (llm_cost_tracker_ingestion_inbox_entries + _leases). " \
           "Required when config.ingestion.mode = :async."

      def create_migration_file
        migration_template(
          "create_llm_cost_tracker_async_ingestion.rb.erb",
          "db/migrate/create_llm_cost_tracker_async_ingestion.rb"
        )
      end

      def warn_about_config_flag
        say(<<~MSG, :yellow)
          After migrating, set the following in config/initializers/llm_cost_tracker.rb:

            LlmCostTracker.configure do |config|
              config.ingestion.mode = :async
            end

          Without it the async inbox tables stay unused and Tracker keeps writing
          inline. The doctor check warns about unused async ingestion tables.
        MSG
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
