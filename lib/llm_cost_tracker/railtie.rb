# frozen_string_literal: true

module LlmCostTracker
  class Railtie < Rails::Railtie
    generators do
      require_relative "generators/llm_cost_tracker/add_daily_totals_generator"
      require_relative "generators/llm_cost_tracker/add_monthly_totals_generator"
      require_relative "generators/llm_cost_tracker/add_latency_ms_generator"
      require_relative "generators/llm_cost_tracker/add_provider_response_id_generator"
      require_relative "generators/llm_cost_tracker/add_streaming_generator"
      require_relative "generators/llm_cost_tracker/add_usage_breakdown_generator"
      require_relative "generators/llm_cost_tracker/install_generator"
      require_relative "generators/llm_cost_tracker/prices_generator"
      require_relative "generators/llm_cost_tracker/upgrade_cost_precision_generator"
      require_relative "generators/llm_cost_tracker/upgrade_tags_to_jsonb_generator"
    end

    rake_tasks do
      load File.expand_path("../tasks/llm_cost_tracker.rake", __dir__)
    end

    initializer "llm_cost_tracker.configure" do
      ActiveSupport.on_load(:active_record) do
        if LlmCostTracker.configuration.active_record?
          require_relative "llm_api_call"
          require_relative "storage/active_record_store"
        end
      end
    end
  end
end
