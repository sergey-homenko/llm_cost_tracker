# frozen_string_literal: true

require "rails"
require_relative "../llm_cost_tracker"
require_relative "engine_compatibility"
require_relative "assets"
require "rack/files"

LlmCostTracker::EngineCompatibility.check_rails_version!(Rails.version)

module LlmCostTracker
  class Engine < ::Rails::Engine
    isolate_namespace LlmCostTracker
  end
end
