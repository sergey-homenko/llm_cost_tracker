# frozen_string_literal: true

require "rails"
require_relative "../llm_cost_tracker"
require_relative "assets"
require "rack/files"

module LlmCostTracker
  class Engine < ::Rails::Engine
    isolate_namespace LlmCostTracker

    initializer "llm_cost_tracker.filter_parameters" do |app|
      app.config.filter_parameters += %i[tag tag_value]
    end
  end
end
