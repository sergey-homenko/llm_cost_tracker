# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"
require "llm_cost_tracker/billing/components"
require "llm_cost_tracker/billing/cost_status"
require "llm_cost_tracker/pricing"
require "llm_cost_tracker/token_usage"

module LlmCostTracker
  module Generators
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Creates the LlmCostTracker migration and initializer"
      class_option :dashboard, type: :boolean, default: false
      class_option :prices, type: :boolean, default: false

      def create_migration_file
        migration_template(
          "create_llm_cost_tracker_calls.rb.erb",
          "db/migrate/create_llm_cost_tracker_calls.rb"
        )
      end

      def create_initializer
        template(
          "initializer.rb.erb",
          "config/initializers/llm_cost_tracker.rb"
        )
      end

      def create_prices_file
        return unless options[:prices]

        require_relative "prices_generator"
        invoke LlmCostTracker::Generators::PricesGenerator
      end

      def mount_engine
        return unless options[:dashboard]

        add_engine_require
        say(<<~MSG, :yellow)
          The LLM Cost Tracker dashboard ships without authentication.
          Mount it in config/routes.rb behind your app's admin auth, e.g.:

            authenticate :admin do
              mount LlmCostTracker::Engine => "/llm-costs"
            end

          The generator does NOT add a route automatically — leaving the dashboard
          unauthenticated would expose spend, tags, and provider IDs to anyone.
        MSG
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end

      def add_engine_require
        return unless File.exist?("config/application.rb")

        contents = File.read("config/application.rb")
        return if contents.include?(%(require "llm_cost_tracker/engine"))

        unless contents.include?(%(require "rails/all"\n))
          prepend_to_file("config/application.rb", %(require "llm_cost_tracker/engine"\n))
          return
        end

        inject_into_file(
          "config/application.rb",
          %(require "llm_cost_tracker/engine"\n),
          after: %(require "rails/all"\n)
        )
      end
    end
  end
end
