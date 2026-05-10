# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module LlmCostTracker
  module Generators
    class CallRollupsGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Creates the optional llm_cost_tracker_call_rollups table for fast budget reads. " \
           "Required when config.cache_rollups = true."

      def create_migration_file
        migration_template(
          "create_llm_cost_tracker_call_rollups.rb.erb",
          "db/migrate/create_llm_cost_tracker_call_rollups.rb"
        )
      end

      def warn_about_config_flag
        say(<<~MSG, :yellow)
          After migrating, set the following in config/initializers/llm_cost_tracker.rb:

            LlmCostTracker.configure do |config|
              config.cache_rollups = true
            end

          Without it Tracker keeps reading budget totals as live SUM aggregates over
          llm_cost_tracker_calls. The doctor check warns about an unused rollups table.
        MSG
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
