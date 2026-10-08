# frozen_string_literal: true

require "spec_helper"
require "open3"

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

  it "boots, eager loads and routes in a host whose inflections define LLM and CSV acronyms" do
    script = <<~RUBY
      require "active_record"
      require "rack/mock"
      require File.expand_path("spec/dummy/config/application")
      Dummy::Application.initializer("host.acronyms") do
        ActiveSupport::Inflector.inflections(:en) { |inflect| %w[LLM CSV].each { |word| inflect.acronym(word) } }
      end
      Dummy::Application.config.eager_load = true
      Dummy::Application.initialize!
      path = "/llm-costs/assets/\#{LlmCostTracker::Assets::STYLESHEET_FILENAME}"
      status = Rack::MockRequest.new(Rails.application).get(path).status
      abort("GET \#{path} returned \#{status}") unless status == 200
    RUBY

    output, status = Open3.capture2e(RbConfig.ruby, "-e", script, chdir: File.expand_path("../..", __dir__))

    expect(status).to be_success, output
  end

  it "aliases the engine namespace under the name a host acronym camelizes it to" do
    inflections = ActiveSupport::Inflector.inflections(:en)
    acronyms = inflections.acronyms.values
    inflections.acronym("LLM")
    Rails.application.reloader.prepare!

    expect(Object.const_get(:LLMCostTracker)).to be(LlmCostTracker)
  ensure
    Object.send(:remove_const, :LLMCostTracker) if Object.const_defined?(:LLMCostTracker, false)
    inflections.clear(:acronyms)
    acronyms.each { |acronym| inflections.acronym(acronym) }
  end

  it "force-loads every gem file the way a production boot does, without raising" do
    expect do
      Rails.application.eager_load!
      LlmCostTracker::Engine.eager_load!
    end.not_to raise_error
  end
end
