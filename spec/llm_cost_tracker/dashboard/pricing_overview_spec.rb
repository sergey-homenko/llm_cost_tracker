# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"

RSpec.describe LlmCostTracker::Dashboard::PricingOverview do
  around do |example|
    Dir.mktmpdir do |dir|
      @prices_path = File.join(dir, "prices.json")
      File.write(@prices_path, JSON.generate(
                                 "metadata" => { "currency" => "EUR", "updated_at" => "2026-05-01" },
                                 "models" => { "openai/gpt-4o" => { "input" => 1.0, "output" => 2.0 } }
                               ))
      example.run
    end
  end

  it "names the overrides option as users write it in the initializer" do
    LlmCostTracker.configure { |config| config.pricing.overrides = { "demo/model" => { "input" => 1.0 } } }

    overrides = described_class.call.fetch(:sources).fetch(:overrides)

    expect(overrides[:subtitle]).to eq("config.pricing.overrides")
  end

  it "shows a scheduled rate from its effective date" do
    LlmCostTracker.configure do |config|
      config.pricing.overrides = { "gemini/gemini-3.8-flash" => { "input" => 0.75, "input_from_2027-01-01" => 1.5 } }
    end
    input_on = ->(time) { travel_to(time) { described_class.call.dig(:sources, :overrides, :rows).first.rates["input"] } }

    expect([input_on.call(Time.utc(2026, 12, 31, 23)), input_on.call(Time.utc(2027, 1, 1))]).to eq([0.75, 1.5])
  end

  it "shows the configured pricing file path and its metadata date" do
    LlmCostTracker.configure { |config| config.pricing.file = @prices_path }

    file = described_class.call.fetch(:sources).fetch(:file)

    expect(file[:subtitle]).to eq(@prices_path)
    expect(file[:updated_at]).to eq("2026-05-01")
    expect(file[:currency]).to eq("EUR")
  end
end
