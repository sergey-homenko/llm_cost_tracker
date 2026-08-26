# frozen_string_literal: true

module LlmCostTracker
  class Railtie < Rails::Railtie
    initializer "llm_cost_tracker.app_models_autoload_paths", before: :set_autoload_paths do |app|
      models_path = File.expand_path("../../app/models", __dir__)
      app.config.autoload_paths << models_path unless app.config.autoload_paths.include?(models_path)
      app.config.eager_load_paths << models_path unless app.config.eager_load_paths.include?(models_path)
    end

    GENERATOR_FILES = File.expand_path("generators/llm_cost_tracker/*_generator.rb", __dir__)

    generators do
      Dir[GENERATOR_FILES].each { |path| require path }
    end
  end
end
