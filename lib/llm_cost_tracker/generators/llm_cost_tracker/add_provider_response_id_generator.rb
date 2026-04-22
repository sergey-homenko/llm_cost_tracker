# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module LlmCostTracker
  module Generators
    class AddProviderResponseIdGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Creates a migration to add llm_api_calls.provider_response_id"

      def create_migration_file
        migration_template(
          "add_provider_response_id_to_llm_api_calls.rb.erb",
          "db/migrate/add_provider_response_id_to_llm_api_calls.rb"
        )
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
