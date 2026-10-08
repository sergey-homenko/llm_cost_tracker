# frozen_string_literal: true

require "rails"
require_relative "../llm_cost_tracker"
require_relative "assets"

module LlmCostTracker
  class Engine < ::Rails::Engine
    isolate_namespace LlmCostTracker

    initializer "llm_cost_tracker.host_inflections" do |app|
      Rails.autoloaders.each { |autoloader| autoloader.inflector.inflect("llm_cost_tracker" => "LlmCostTracker") }
      app.reloader.to_prepare do
        host_name = "llm_cost_tracker".camelize
        Object.const_set(host_name, LlmCostTracker) unless Object.const_defined?(host_name)
      end
    end

    initializer "llm_cost_tracker.deprecator" do |app|
      app.deprecators[:llm_cost_tracker] = LlmCostTracker.deprecator
    end

    initializer "llm_cost_tracker.dashboard_setup_state" do |app|
      app.reloader.to_prepare { LlmCostTracker::Dashboard::SetupState.reset! }
    end

    initializer "llm_cost_tracker.pricing_cache" do |app|
      app.reloader.to_prepare { LlmCostTracker::Pricing::Registry.reset! }
    end
  end
end
