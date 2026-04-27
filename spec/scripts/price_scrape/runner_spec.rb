# frozen_string_literal: true

require "spec_helper"
require "json"
require "stringio"
require "tempfile"
require "price_scrape/runner"

RSpec.describe LlmCostTracker::PriceScrape::Runner do
  let(:io) { StringIO.new }
  let(:html) { File.read("spec/fixtures/scrape/anthropic_pricing.html", encoding: "utf-8") }

  def build_registry(haiku_entry:)
    {
      "metadata" => { "schema_version" => 1, "updated_at" => "2026-04-01" },
      "models" => { "claude-haiku-4-5" => haiku_entry }
    }
  end

  before do
    stub_request(:get, LlmCostTracker::PriceScrape::Providers::Anthropic::SOURCE_URL)
      .to_return(status: 200, body: html, headers: { "Content-Type" => "text/html; charset=utf-8" })
  end

  it "fetches, parses, and applies changes for the configured provider" do
    Tempfile.create(["registry", ".json"]) do |file|
      file.write(JSON.pretty_generate(build_registry(haiku_entry: { "input" => 1.0, "output" => 5.0 })))
      file.close

      runs = described_class.new(io: io).call(providers: ["anthropic"], registry_path: file.path)

      expect(runs.size).to eq(1)
      orchestrator_result = runs.first.orchestrator
      expect(orchestrator_result.written).to be(true)
      expect(orchestrator_result.added).to include("claude-opus-4-7", "claude-sonnet-4-6")
      expect(orchestrator_result.updated["claude-haiku-4-5"]).to include(
        "batch_input" => { "from" => nil, "to" => 0.5 }
      )

      written = JSON.parse(File.read(file.path))
      expect(written.dig("models", "claude-opus-4-7", "input")).to eq(5.0)
      expect(written["models"]).not_to have_key("claude-sonnet-3-7")
    end
  end

  it "does not write in dry_run mode" do
    Tempfile.create(["registry", ".json"]) do |file|
      original = JSON.pretty_generate(build_registry(haiku_entry: { "input" => 1.0, "output" => 5.0 }))
      file.write(original)
      file.close

      runs = described_class.new(io: io).call(
        providers: ["anthropic"],
        registry_path: file.path,
        dry_run: true
      )

      expect(runs.first.orchestrator.changed?).to be(true)
      expect(runs.first.orchestrator.written).to be(false)
      expect(File.read(file.path)).to eq(original)
    end
  end

  it "raises on an unknown provider name" do
    expect do
      described_class.new(io: io).call(providers: ["xai"])
    end.to raise_error(described_class::Error, /unknown providers/)
  end

  it "marks a provider run as failed and raises after the loop when its parser breaks" do
    stub_request(:get, LlmCostTracker::PriceScrape::Providers::Anthropic::SOURCE_URL)
      .to_return(status: 200, body: "<html><body></body></html>",
                 headers: { "Content-Type" => "text/html; charset=utf-8" })

    Tempfile.create(["registry", ".json"]) do |file|
      file.write(JSON.pretty_generate(build_registry(haiku_entry: { "input" => 1.0, "output" => 5.0 })))
      file.close

      expect do
        described_class.new(io: io).call(providers: ["anthropic"], registry_path: file.path)
      end.to raise_error(described_class::Error, /provider scrape failures: anthropic/)

      expect(io.string).to include("[anthropic] FAILED:")
      expect(io.string).to include("[summary] providers=1 ok=0 failed=1")
    end
  end

  it "continues running remaining providers when one fails" do
    stub_request(:get, LlmCostTracker::PriceScrape::Providers::Gemini::SOURCE_URL)
      .to_return(status: 200, body: "<html><body></body></html>",
                 headers: { "Content-Type" => "text/html; charset=utf-8" })

    Tempfile.create(["registry", ".json"]) do |file|
      file.write(JSON.pretty_generate(build_registry(haiku_entry: { "input" => 1.0, "output" => 5.0 })))
      file.close

      expect do
        described_class.new(io: io).call(providers: %w[anthropic gemini], registry_path: file.path)
      end.to raise_error(described_class::Error, /provider scrape failures: gemini/)

      expect(io.string).to include("[anthropic] parsed")
      expect(io.string).to include("[gemini] FAILED:")
      expect(io.string).to include("[summary] providers=2 ok=1 failed=1")
    end
  end
end
