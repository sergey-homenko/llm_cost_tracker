# frozen_string_literal: true

require "rake"
require "spec_helper"
require "tmpdir"

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

  it "previews suspicious price changes and writes them only with FORCE=1" do
    url = "https://prices.example.com/prices.json"
    stub_request(:get, url).to_return(body: JSON.generate("models" => { "openai/gpt-4o" => { "input" => 0.0 } }))

    Dir.mktmpdir do |dir|
      path = File.join(dir, "llm_cost_tracker_prices.yml")
      File.write(path, { "models" => { "openai/gpt-4o" => { "input" => 2.5 } } }.to_yaml)
      base_env = ENV.to_h.merge("OUTPUT" => path, "URL" => url)
      refresh = lambda do |env|
        stub_const("ENV", base_env.merge(env))
        Rake::Task["llm_cost_tracker:prices:refresh"].execute
      end

      expect { refresh.call("PREVIEW" => "1") }.to output(
        %r{suspicious changes \(refresh writes them only with FORCE=1\): 1\n    - openai/gpt-4o input: 2.5 -> 0.0}
      ).to_stdout
      expect { refresh.call({}) }.to raise_error(LlmCostTracker::Error, /Refusing to write pricing file/)
      expect { refresh.call("FORCE" => "1") }.to output(/refreshed pricing file/).to_stdout
      expect(YAML.safe_load_file(path).dig("models", "openai/gpt-4o", "input")).to eq(0.0)
    end
  end

  it "does not register tasks from the Railtie because the Engine already auto-loads lib/tasks" do
    railtie_source = File.read(File.expand_path("../../lib/llm_cost_tracker/railtie.rb", __dir__))
    expect(railtie_source).not_to include("rake_tasks do")
  end
end
