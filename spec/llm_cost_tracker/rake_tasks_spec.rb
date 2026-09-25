# frozen_string_literal: true

require "json"
require "rake"
require "spec_helper"
require "tmpdir"
require "yaml"

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

  describe "llm_cost_tracker:prices:refresh" do
    let(:url) { "https://prices.example.com/prices.json" }

    around do |example|
      Dir.mktmpdir do |dir|
        @prices_path = File.join(dir, "llm_cost_tracker_prices.yml")
        File.write(
          @prices_path,
          { "metadata" => {}, "models" => { "openai/gpt-4o" => { "input" => 2.5, "output" => 10.0 } } }.to_yaml
        )
        example.run
      end
    end

    before do
      stub_request(:get, url).to_return(
        status: 200,
        body: JSON.generate("models" => { "openai/gpt-4o" => { "input" => 0.0, "output" => 10.0 } })
      )
    end

    def refresh_prices(env)
      stub_const("ENV", ENV.to_h.merge("OUTPUT" => @prices_path, "URL" => url).merge(env))
      Rake::Task["llm_cost_tracker:prices:refresh"].invoke
    end

    it "refuses a snapshot that zeroes a price and keeps the local file" do
      original = File.read(@prices_path)

      expect { refresh_prices({}) }.to raise_error(LlmCostTracker::Error, /openai\/gpt-4o input: 2.5 -> 0.0/)
      expect(File.read(@prices_path)).to eq(original)
    end

    it "previews the suspicious change without writing it" do
      original = File.read(@prices_path)

      expect { refresh_prices("PREVIEW" => "1") }.to output(
        /suspicious changes \(refresh writes them only with FORCE=1\): 1\n    - openai\/gpt-4o input: 2.5 -> 0.0/
      ).to_stdout
      expect(File.read(@prices_path)).to eq(original)
    end

    it "writes the snapshot when FORCE=1 is set" do
      expect { refresh_prices("FORCE" => "1") }.to output(/refreshed pricing file/).to_stdout
      expect(YAML.safe_load_file(@prices_path).dig("models", "openai/gpt-4o", "input")).to eq(0.0)
    end
  end

  it "does not register tasks from the Railtie because the Engine already auto-loads lib/tasks" do
    railtie_source = File.read(File.expand_path("../../lib/llm_cost_tracker/railtie.rb", __dir__))
    expect(railtie_source).not_to include("rake_tasks do")
  end
end
