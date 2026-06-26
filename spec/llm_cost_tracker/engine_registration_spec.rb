# frozen_string_literal: true

require "spec_helper"

ENV["RAILS_ENV"] ||= "test"

require_relative "../dummy/config/environment"

RSpec.describe "LlmCostTracker::Engine registration" do
  it "adds the engine routes to the host reloader at boot without an explicit require" do
    engine_routes = LlmCostTracker::Engine.paths["config/routes.rb"].existent

    expect(engine_routes).not_to be_empty
    expect(Rails.application.routes_reloader.paths).to include(*engine_routes)
  end
end
