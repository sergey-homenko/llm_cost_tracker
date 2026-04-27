# frozen_string_literal: true

require "spec_helper"
require "price_scrape/providers/gemini"

RSpec.describe LlmCostTracker::PriceScrape::Providers::Gemini do
  let(:fixture_path) { File.expand_path("../../../fixtures/scrape/gemini_pricing.html", __dir__) }
  let(:html) { File.read(fixture_path, encoding: "utf-8") }

  describe "#call" do
    it "extracts standard text input/output rates for current models" do
      result = described_class.new.call(html: html, scraped_at: "2026-04-26T00:00:00Z")

      expect(result.source_url).to eq(described_class::SOURCE_URL)
      expect(result.scraped_at).to eq("2026-04-26T00:00:00Z")
      expect(result.models.fetch("gemini-2.5-pro")).to eq(
        "input" => 1.25,
        "output" => 10.0
      )
      expect(result.models.fetch("gemini-2.5-flash")).to eq(
        "input" => 0.30,
        "output" => 2.50
      )
      expect(result.models.fetch("gemini-2.0-flash")).to eq(
        "input" => 0.10,
        "output" => 0.40
      )
      expect(result.models.fetch("gemini-2.0-flash-lite")).to eq(
        "input" => 0.075,
        "output" => 0.30
      )
    end

    it "returns at least the minimum expected number of models" do
      result = described_class.new.call(html: html)
      expect(result.models.size).to be >= described_class::MIN_MODELS_EXPECTED
    end

    it "sets deprecated_models to empty" do
      result = described_class.new.call(html: html)
      expect(result.deprecated_models).to eq([])
    end

    it "skips preview and dated snapshot models" do
      result = described_class.new.call(html: html)

      expect(result.models.keys).to all(satisfy { |id| !id.include?("-preview") })
    end

    it "raises when the pricing article body is missing" do
      expect do
        described_class.new.call(html: "<html><body></body></html>")
      end.to raise_error(described_class::Error, /article body not found/)
    end

    it "raises when standard pricing tables are missing" do
      tableless_html = html.gsub(%r{<table\b.*?</table>}m, "")

      expect do
        described_class.new.call(html: tableless_html)
      end.to raise_error(described_class::Error, /at least \d+ models/)
    end

    it "raises when the parsed model count is below the minimum" do
      sparse_html = <<~HTML
        <html><body>
          <div class="devsite-article-body clearfix">
            <div class="models-section">
              <div class="heading-group">
                <h2>Gemini 2.5 Pro</h2>
                <em><code>gemini-2.5-pro</code></em>
              </div>
            </div>
            <div class="ds-selector-tabs">
              <section>
                <h3>Standard</h3>
                <table>
                  <thead>
                    <tr><th></th><th>Free Tier</th><th>Paid Tier, per 1M tokens in USD</th></tr>
                  </thead>
                  <tbody>
                    <tr><td>Input price</td><td>Free</td><td>$1.25, prompts &lt;= 200k tokens</td></tr>
                    <tr><td>Output price</td><td>Free</td><td>$10.00, prompts &lt;= 200k tokens</td></tr>
                  </tbody>
                </table>
              </section>
            </div>
          </div>
        </body></html>
      HTML

      expect do
        described_class.new.call(html: sparse_html)
      end.to raise_error(described_class::Error, /at least \d+ models/)
    end

    it "raises when a price cell does not match the expected format" do
      broken_html = html.sub("$0.075", "TBD")
      expect do
        described_class.new.call(html: broken_html)
      end.to raise_error(described_class::Error, /unable to parse price/)
    end
  end
end
