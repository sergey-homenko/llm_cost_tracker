# frozen_string_literal: true

require "spec_helper"
require "price_scrape/providers/anthropic"

RSpec.describe LlmCostTracker::PriceScrape::Providers::Anthropic do
  let(:fixture_path) { File.expand_path("../../../fixtures/scrape/anthropic_pricing.html", __dir__) }
  let(:html) { File.read(fixture_path, encoding: "utf-8") }

  describe "#call" do
    it "extracts current model pricing from the official page" do
      result = described_class.new.call(html: html, scraped_at: "2026-04-26T00:00:00Z")

      expect(result.source_url).to eq(described_class::SOURCE_URL)
      expect(result.scraped_at).to eq("2026-04-26T00:00:00Z")
      expect(result.models.fetch("claude-opus-4-7")).to eq(
        "input" => 5.0,
        "cache_write_input" => 6.25,
        "cache_read_input" => 0.5,
        "output" => 25.0,
        "batch_input" => 2.5,
        "batch_output" => 12.5
      )
      expect(result.models.fetch("claude-sonnet-4-6")).to eq(
        "input" => 3.0,
        "cache_write_input" => 3.75,
        "cache_read_input" => 0.30,
        "output" => 15.0,
        "batch_input" => 1.5,
        "batch_output" => 7.5
      )
      expect(result.models.fetch("claude-haiku-4-5")).to include(
        "input" => 1.0,
        "output" => 5.0,
        "batch_input" => 0.5,
        "batch_output" => 2.5
      )
    end

    it "extracts deprecated models that still match the canonical naming pattern" do
      result = described_class.new.call(html: html)
      expect(result.models).to include("claude-sonnet-3-7", "claude-opus-3", "claude-haiku-3")
    end

    it "flags deprecated models separately from the price table" do
      result = described_class.new.call(html: html)

      expect(result.deprecated_models).to contain_exactly("claude-sonnet-3-7", "claude-opus-3")
      expect(result.models).to include("claude-sonnet-3-7", "claude-opus-3")
    end

    it "leaves deprecated_models empty when the page has no deprecation links" do
      stripped = html.gsub(%r{<a [^>]*href="[^"]*model-deprecations[^"]*"[^>]*>[^<]*</a>}, "")
      result = described_class.new.call(html: stripped)

      expect(result.deprecated_models).to eq([])
    end

    it "returns at least the minimum expected number of models" do
      result = described_class.new.call(html: html)
      expect(result.models.size).to be >= described_class::MIN_MODELS_EXPECTED
    end

    it "raises when the base pricing table is missing" do
      expect do
        described_class.new.call(html: "<html><body></body></html>")
      end.to raise_error(described_class::Error, /base pricing table not found/)
    end

    it "raises when the parsed model count is below the minimum" do
      sparse_html = <<~HTML
        <html><body>
          <table>
            <thead><tr>
              <th>Model</th><th>Base Input Tokens</th><th>5m Cache Writes</th>
              <th>1h Cache Writes</th><th>Cache Hits & Refreshes</th><th>Output Tokens</th>
            </tr></thead>
            <tbody>
              <tr><td>Claude Opus 4.7</td><td>$5 / MTok</td><td>$6.25 / MTok</td>
                <td>$10 / MTok</td><td>$0.50 / MTok</td><td>$25 / MTok</td></tr>
            </tbody>
          </table>
        </body></html>
      HTML

      expect do
        described_class.new.call(html: sparse_html)
      end.to raise_error(described_class::Error, /at least \d+ models/)
    end

    it "raises when a price cell does not match the expected format" do
      broken_html = html.sub("$5 / MTok", "TBD")
      expect do
        described_class.new.call(html: broken_html)
      end.to raise_error(described_class::Error, /unable to parse price/)
    end
  end
end
