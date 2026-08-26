# frozen_string_literal: true

require "spec_helper"

ENV["RAILS_ENV"] ||= "test"

require_relative "../dummy/config/environment"

RSpec.describe "LlmCostTracker boot" do
  it "registers the engine routes in the host reloader without an explicit require" do
    engine_routes = LlmCostTracker::Engine.paths["config/routes.rb"].existent

    expect(engine_routes).not_to be_empty
    expect(Rails.application.routes_reloader.paths).to include(*engine_routes)
  end

  it "hands Rails every generator that ships in the gem" do
    Rails.application.load_generators

    on_disk = Dir[LlmCostTracker::Railtie::GENERATOR_FILES].map { |path| File.basename(path, "_generator.rb") }
    registered = Rails::Generators.subclasses.filter_map do |klass|
      klass.name[/\ALlmCostTracker::Generators::(\w+)Generator\z/, 1]&.underscore
    end

    expect(on_disk).not_to be_empty
    expect(registered).to include(*on_disk)
  end

  it "force-loads every gem file the way a production boot does, without raising" do
    expect do
      Rails.application.eager_load!
      LlmCostTracker::Engine.eager_load!
    end.not_to raise_error
  end
end
