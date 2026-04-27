# frozen_string_literal: true

require "cgi"
require "json"
require "spec_helper"
require "price_scrape/providers/openai"

RSpec.describe LlmCostTracker::PriceScrape::Providers::Openai do
  let(:fixture_path) { File.expand_path("../../../fixtures/scrape/openai_pricing.html", __dir__) }
  let(:html) { File.read(fixture_path, encoding: "utf-8") }

  def sparse_html
    props = {
      "tier" => [0, "standard"],
      "rows" => [1, [[1, [[0, "gpt-5"], [0, 1.25], [0, 0.125], [0, 10]]]]]
    }
    escaped_props = CGI.escapeHTML(JSON.generate(props))
    "<html><body><astro-island component-url=\"/_astro/pricing.test.js\" " \
      "props=\"#{escaped_props}\"></astro-island></body></html>"
  end

  describe "#call" do
    it "extracts standard text input/output rates for current models" do
      result = described_class.new.call(html: html, scraped_at: "2026-04-26T00:00:00Z")

      expect(result.source_url).to eq(described_class::SOURCE_URL)
      expect(result.scraped_at).to eq("2026-04-26T00:00:00Z")
      expect(result.models.fetch("gpt-5.5")).to eq(
        "input" => 5.0,
        "cache_read_input" => 0.5,
        "output" => 30.0
      )
      expect(result.models.fetch("gpt-5.4-mini")).to eq(
        "input" => 0.75,
        "cache_read_input" => 0.075,
        "output" => 4.5
      )
      expect(result.models.fetch("gpt-4-turbo")).to eq(
        "input" => 10.0,
        "output" => 30.0
      )
      expect(result.models.fetch("gpt-5.2-codex")).to eq(
        "input" => 1.75,
        "cache_read_input" => 0.175,
        "output" => 14.0
      )
      expect(result.models.fetch("o3-pro")).to eq(
        "input" => 20.0,
        "output" => 80.0
      )
      expect(result.models.fetch("gpt-5.5-pro").keys).to contain_exactly("input", "output")
    end

    it "returns at least the minimum expected number of models" do
      result = described_class.new.call(html: html)
      expect(result.models.size).to be >= described_class::MIN_MODELS_EXPECTED
    end

    it "sets deprecated_models to empty" do
      result = described_class.new.call(html: html)
      expect(result.deprecated_models).to eq([])
    end

    it "skips unmapped model rows instead of guessing canonical IDs" do
      result = described_class.new.call(html: html)

      expect(result.models).not_to include("gpt-4-32k", "davinci-002", "babbage-002")
    end

    it "raises when the standard pricing table is missing" do
      expect do
        described_class.new.call(html: "<html><body></body></html>")
      end.to raise_error(described_class::Error, /standard pricing table not found/)
    end

    it "raises when the parsed model count is below the minimum" do
      expect do
        described_class.new.call(html: sparse_html)
      end.to raise_error(described_class::Error, /at least \d+ models/)
    end

    it "raises when a price cell does not match the expected format" do
      broken_html = html.sub("[0,5],[0,0.5],[0,30]", "[0,&quot;TBD&quot;],[0,0.5],[0,30]")

      expect do
        described_class.new.call(html: broken_html)
      end.to raise_error(described_class::Error, /unable to parse price/)
    end
  end
end
