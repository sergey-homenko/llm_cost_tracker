# frozen_string_literal: true

require "rake"
require "spec_helper"
require "llm_cost_tracker/pricing/backfill"
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

  after { disconnect_database! }

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

  it "lists suspicious price changes in prices:check and writes them only with FORCE=1" do
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

      check = lambda do
        stub_const("ENV", base_env)
        Rake::Task["llm_cost_tracker:prices:check"].execute
      end

      expect { check.call }.to output(
        %r{suspicious changes \(refresh writes them only with FORCE=1\): 1\n    - openai/gpt-4o input: 2.5 -> 0.0}
      ).to_stdout.and raise_error(SystemExit)
      expect { refresh.call("PREVIEW" => "1") }.to raise_error(SystemExit)
      expect(YAML.safe_load_file(path).dig("models", "openai/gpt-4o", "input")).to eq(2.5)
      expect { refresh.call({}) }.to raise_error(LlmCostTracker::Error, /Refusing to write pricing file/)
      expect { refresh.call("FORCE" => "1") }.to output(/refreshed pricing file/).to_stdout
      expect(YAML.safe_load_file(path).dig("models", "openai/gpt-4o", "input")).to eq(0.0)
    end
  end

  it "backfills the calls a new config.pricing.file prices, not when the file is kept or written elsewhere" do
    establish_database_connection!
    create_lct_tables!
    [LlmCostTracker::Call, LlmCostTracker::CallLineItem, LlmCostTracker::CallTag, LlmCostTracker::CallRollup]
      .each(&:reset_column_information)
    Rake::Task.define_task(:environment)
    url = "https://prices.example.com/prices.json"
    stub_request(:get, url).to_return(
      body: JSON.generate("models" => { "openai/acme-late-model" => { "input" => 1.0, "output" => 2.0 } }),
      headers: { "ETag" => '"v1"' }
    )
    stub_request(:get, url).with(headers: { "If-None-Match" => '"v1"' }).to_return(status: 304)
    allow(LlmCostTracker::Pricing::Backfill).to receive(:call).and_call_original

    Dir.mktmpdir do |dir|
      LlmCostTracker.configure { |config| config.pricing.file = File.join(dir, "llm_cost_tracker_prices.yml") }
      LlmCostTracker.track(provider: "openai", model: "acme-late-model",
                           tokens: { input_tokens: 1000, output_tokens: 100 })
      refresh = lambda do |output|
        stub_const("ENV", ENV.to_h.merge("OUTPUT" => File.join(dir, output), "URL" => url))
        Rake::Task["llm_cost_tracker:prices:refresh"].execute
      end

      expect { refresh.call("staged.yml") }
        .to output(/\Allm_cost_tracker: refreshed pricing file [^\n]*staged.yml\n(?!.*llm_cost_tracker:)/m).to_stdout
      expect(LlmCostTracker::Call.sole.cost_status).to eq("unknown")
      expect { refresh.call("./llm_cost_tracker_prices.yml") }.to output(
        /refreshed pricing file.*\nllm_cost_tracker: examined 1 calls, recomputed 1, still unknown 0\n\z/m
      ).to_stdout
      expect(LlmCostTracker::Call.sole).to have_attributes(total_cost: BigDecimal("0.0012"), cost_status: "complete")
      expect { refresh.call("llm_cost_tracker_prices.yml") }.to output(/kept pricing file/).to_stdout
      expect(LlmCostTracker::Pricing::Backfill).to have_received(:call).once
    end
  end

  it "keeps a new config.pricing.file and prints the backfill command when the calls ledger is not reachable" do
    url = "https://prices.example.com/prices.json"
    stub_request(:get, url).to_return(body: JSON.generate("models" => {}))
    hinted = %r{refreshed pricing file.*\nllm_cost_tracker: calls ledger not reachable; run bin/rails llm_cost_tracker:backfill_unknown_pricing where it is\n\z}m

    Dir.mktmpdir do |dir|
      path = File.join(dir, "prices.yml")
      LlmCostTracker.configure { |config| config.pricing.file = path }
      stub_const("ENV", ENV.to_h.merge("OUTPUT" => path, "URL" => url))
      refresh = -> { Rake::Task["llm_cost_tracker:prices:refresh"].execute }
      establish_database_connection!
      create_lct_tables!

      expect { refresh.call }.to output(hinted).to_stdout
      Rake::Task.define_task(:environment)
      drop_lct_tables!
      expect { refresh.call }.to output(hinted).to_stdout
      LlmCostTracker::Call.establish_connection(LlmCostTrackerDatabase.config.merge(port: 1))
      expect { refresh.call }.to output(hinted).to_stdout
    ensure
      LlmCostTracker::Call.remove_connection
    end
  end

  it "reprices calls from FROM up to TO and refuses to run without FROM or with an unreadable TO" do
    backfill = LlmCostTracker::Pricing::Backfill
    allow(backfill).to receive(:reprice_scope).and_return(:scope)
    allow(backfill).to receive(:call).and_return(backfill::Result.new(examined: 2, recomputed: 1, still_unknown: 1))
    reprice = lambda do |env|
      stub_const("ENV", ENV.to_h.except("FROM", "TO").merge(env))
      Rake::Task["llm_cost_tracker:reprice"].execute
    end

    expect { reprice.call("FROM" => "2026-09-21", "TO" => "2026-09-27") }
      .to output("llm_cost_tracker: examined 2 calls, repriced 1\n").to_stdout
    expect(backfill).to have_received(:reprice_scope).with(Time.utc(2026, 9, 21)...Time.utc(2026, 9, 27))
    expect(backfill).to have_received(:call).with(scope: :scope, batch_size: 500, reprice: true)
    expect { reprice.call({}) }.to raise_error(SystemExit).and output(/set FROM/).to_stderr
    expect { reprice.call("FROM" => "2026-09-21", "TO" => "yesterday") }
      .to raise_error(SystemExit).and output(/TO=yesterday is not a date/).to_stderr
    expect(backfill).to have_received(:call).once
  end

  it "does not register tasks from the Railtie because the Engine already auto-loads lib/tasks" do
    railtie_source = File.read(File.expand_path("../../lib/llm_cost_tracker/railtie.rb", __dir__))
    expect(railtie_source).not_to include("rake_tasks do")
  end
end
