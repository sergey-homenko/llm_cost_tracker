# frozen_string_literal: true

require "spec_helper"
require "json"
require "price_scrape/providers/openrouter"

RSpec.describe LlmCostTracker::Pricing::Scrape::Providers::Openrouter do
  let(:body) { File.read("spec/fixtures/scrape/openrouter_models.json", encoding: "utf-8") }
  let(:result) { described_class.new.call(html: body) }

  it "parses the live catalogue against the real min_models threshold and converts per-token prices to per-million" do
    expect(result.models.size).to be >= described_class.min_models
    expect(result.models).to include(
      "openai/gpt-4o" => a_hash_including("input" => 2.5, "output" => 10.0),
      "anthropic/claude-sonnet-4" => a_hash_including(
        "input" => 3.0, "output" => 15.0, "cache_read_input" => 0.3, "cache_write_input" => 3.75
      )
    )
  end

  it "drops models priced with the -1 unavailable sentinel instead of emitting a negative rate" do
    %w[openrouter/auto openrouter/fusion openrouter/pareto-code openrouter/bodybuilder].each do |id|
      expect(result.models).not_to have_key(id)
    end
  end

  it "skips zero-priced free-tier models so they don't pollute the registry with 0.0 rates" do
    expect(result.models).not_to have_key("openrouter/owl-alpha")
  end

  it "ignores per-request fields like web_search so a $0.01/call rate isn't misread as a per-token price" do
    sonnet = result.models.fetch("anthropic/claude-sonnet-4")
    expect(sonnet.keys).not_to include("web_search", "web_search_request", "request")
  end

  it "raises when the catalogue drops below the minimum threshold (catches API breakage)" do
    trimmed = JSON.generate("data" => JSON.parse(body).fetch("data").first(5))
    expect { described_class.new.call(html: trimmed) }
      .to raise_error(described_class::Error, /expected at least #{described_class.min_models} models/)
  end

  it "raises when an anchor model disappears so a silent rename can't wipe the registry" do
    catalogue = JSON.parse(body)
    catalogue.fetch("data").reject! { |entry| entry["id"] == "openai/gpt-4o" }
    expect { described_class.new.call(html: JSON.generate(catalogue)) }
      .to raise_error(described_class::Error, /anchor models missing from scrape/)
  end

  it "raises on invalid JSON so a broken endpoint doesn't silently wipe the registry" do
    expect { described_class.new.call(html: "<html>not json</html>") }
      .to raise_error(described_class::Error, /invalid JSON/)
  end
end
