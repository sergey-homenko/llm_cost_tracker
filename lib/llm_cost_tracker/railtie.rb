# frozen_string_literal: true

module LlmCostTracker
  class Railtie < Rails::Railtie
    generators do
      require_relative "generators/llm_cost_tracker/install_generator"
    end

    initializer "llm_cost_tracker.configure" do
      # Auto-require ActiveRecord storage if configured
      ActiveSupport.on_load(:active_record) do
        if LlmCostTracker.configuration.active_record?
          require_relative "llm_api_call"
          require_relative "storage/active_record_store"
        end
      end
    end
  end
end
