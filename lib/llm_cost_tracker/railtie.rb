# frozen_string_literal: true

module LlmCostTracker
  class Railtie < Rails::Railtie
    initializer "llm_cost_tracker.app_models_autoload_paths", before: :set_autoload_paths do |app|
      models_path = File.expand_path("../../app/models", __dir__)
      app.config.autoload_paths << models_path unless app.config.autoload_paths.include?(models_path)
      app.config.eager_load_paths << models_path unless app.config.eager_load_paths.include?(models_path)
    end

    generators do
      require_relative "generators/llm_cost_tracker/install_generator"
      require_relative "generators/llm_cost_tracker/prices_generator"
      require_relative "generators/llm_cost_tracker/call_rollups_generator"
      require_relative "generators/llm_cost_tracker/durable_ingestion_generator"
      require_relative "generators/llm_cost_tracker/reconciliation_generator"
      require_relative "generators/llm_cost_tracker/upgrade_call_rollups_provider_generator"
    end

    rake_tasks do
      load File.expand_path("../tasks/llm_cost_tracker.rake", __dir__)
    end
  end
end
