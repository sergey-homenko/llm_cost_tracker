# frozen_string_literal: true

require "rake"
require "spec_helper"

RSpec.describe "llm_cost_tracker rake tasks" do
  around do |example|
    previous_application = Rake.application
    Rake.application = Rake::Application.new
    load File.expand_path("../../lib/tasks/llm_cost_tracker.rake", __dir__)
    example.run
  ensure
    Rake.application = previous_application
  end

  it "sets up a fresh install with dashboard, prices, migrations, and doctor" do
    migrate = instance_double(Rake::Task, invoke: true)
    doctor = instance_double(Rake::Task, invoke: true)

    allow(Rails::Generators).to receive(:invoke)
    allow(Rake::Task).to receive(:[]).and_call_original
    allow(Rake::Task).to receive(:[]).with("db:migrate").and_return(migrate)
    allow(Rake::Task).to receive(:[]).with("llm_cost_tracker:doctor").and_return(doctor)

    Rake::Task["llm_cost_tracker:setup"].invoke

    expect(Rails::Generators).to have_received(:invoke).with(
      "llm_cost_tracker:install", %w[--dashboard --prices --skip]
    )
    expect(migrate).to have_received(:invoke)
    expect(doctor).to have_received(:invoke)
  end

  it "does not register tasks from the Railtie because the Engine already auto-loads lib/tasks" do
    railtie_source = File.read(File.expand_path("../../lib/llm_cost_tracker/railtie.rb", __dir__))
    expect(railtie_source).not_to include("rake_tasks do")
  end
end
