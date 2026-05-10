# frozen_string_literal: true

require "rails"
require_relative "../llm_cost_tracker"
require_relative "assets"
require_relative "dashboard_setup_state"
require "rack/files"

module LlmCostTracker
  class Engine < ::Rails::Engine
    isolate_namespace LlmCostTracker

    initializer "llm_cost_tracker.filter_parameters" do |app|
      app.config.filter_parameters += %i[tag tag_value]
    end

    initializer "llm_cost_tracker.dashboard_setup_state" do |app|
      app.reloader.to_prepare { LlmCostTracker::DashboardSetupState.reset! }
    end
  end
end
