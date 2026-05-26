# frozen_string_literal: true

require "spec_helper"
require "price_scrape/providers/gemini"

RSpec.describe LlmCostTracker::Pricing::Scrape::Providers::Gemini do
  let(:fixture_path) { File.expand_path("../../../fixtures/scrape/gemini_pricing.html", __dir__) }
  let(:html) { File.read(fixture_path, encoding: "utf-8") }

  describe "#call" do
    it "extracts standard and batch text input/output rates for current models" do
      result = described_class.new.call(html: html, scraped_at: "2026-04-26T00:00:00Z")

      expect(result.source_url).to eq(described_class.source_url)
      expect(result.scraped_at).to eq("2026-04-26T00:00:00Z")
      expect(result.models.fetch("gemini-2.5-pro")).to eq(
        "input" => 1.25,
        "output" => 10.0,
        "cache_read_input" => 0.125,
        "batch_input" => 0.625,
        "batch_output" => 5.0,
        "batch_cache_read_input" => 0.125,
        "_context_price_threshold_tokens" => 200_000,
        "above_context_input" => 2.5,
        "above_context_output" => 15.0,
        "above_context_cache_read_input" => 0.25,
        "above_context_batch_input" => 1.25,
        "above_context_batch_output" => 7.5,
        "above_context_batch_cache_read_input" => 0.25,
        "flex_input" => 0.625,
        "flex_output" => 5.0,
        "flex_cache_read_input" => 0.125,
        "above_context_flex_input" => 1.25,
        "above_context_flex_output" => 7.5,
        "above_context_flex_cache_read_input" => 0.25,
        "priority_input" => 2.25,
        "priority_output" => 18.0,
        "priority_cache_read_input" => 0.225,
        "above_context_priority_input" => 4.5,
        "above_context_priority_output" => 27.0,
        "above_context_priority_cache_read_input" => 0.45
      )
      expect(result.models.fetch("gemini-2.5-flash")).to eq(
        "input" => 0.30,
        "output" => 2.50,
        "audio_input" => 1.0,
        "cache_read_input" => 0.03,
        "batch_input" => 0.15,
        "batch_output" => 1.25,
        "batch_audio_input" => 0.5,
        "batch_cache_read_input" => 0.03,
        "flex_input" => 0.15,
        "flex_output" => 1.25,
        "flex_audio_input" => 0.5,
        "flex_cache_read_input" => 0.03,
        "priority_input" => 0.54,
        "priority_output" => 4.5,
        "priority_audio_input" => 1.8,
        "priority_cache_read_input" => 0.054
      )
      expect(result.models.fetch("gemini-2.5-flash-lite")).to include(
        "audio_input" => 0.30,
        "batch_audio_input" => 0.15,
        "flex_audio_input" => 0.15,
        "priority_audio_input" => 0.54
      )
      expect(result.models.fetch("gemini-2.0-flash")).to eq(
        "input" => 0.10,
        "output" => 0.40,
        "audio_input" => 0.70,
        "cache_read_input" => 0.025,
        "batch_input" => 0.05,
        "batch_output" => 0.20,
        "batch_audio_input" => 0.35,
        "batch_cache_read_input" => 0.025
      )
      expect(result.models.fetch("gemini-2.0-flash-lite")).to eq(
        "input" => 0.075,
        "output" => 0.30,
        "batch_input" => 0.0375,
        "batch_output" => 0.15
      )
    end

    it "returns at least the minimum expected number of models" do
      result = described_class.new.call(html: html)
      expect(result.models.size).to be >= described_class.min_models
    end

    it "sets deprecated_models to empty" do
      result = described_class.new.call(html: html)
      expect(result.deprecated_models).to eq([])
    end

    it "includes preview models alongside stable text models so dated/preview snapshots get priced" do
      result = described_class.new.call(html: html)

      preview_ids = result.models.keys.select { |id| id.include?("-preview") }
      expect(preview_ids).not_to be_empty
    end

    it "routes image-model output rates to image_output keys so text output rate stays clean" do
      result = described_class.new.call(html: html)

      image_model = result.models["gemini-2.5-flash-image"]
      expect(image_model).to include("input", "image_output", "batch_image_output", "flex_image_output",
                                     "priority_image_output")
      expect(image_model).not_to include("output", "batch_output", "flex_output", "priority_output")
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
              <section>
                <h3>Batch</h3>
                <table>
                  <thead>
                    <tr><th></th><th>Free Tier</th><th>Paid Tier, per 1M tokens in USD</th></tr>
                  </thead>
                  <tbody>
                    <tr><td>Input price</td><td>Not available</td><td>$0.625, prompts &lt;= 200k tokens</td></tr>
                    <tr><td>Output price</td><td>Not available</td><td>$5.00, prompts &lt;= 200k tokens</td></tr>
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

    it "raises when a batch price cell does not match the expected format" do
      broken_html = html.sub("$0.0375", "TBD")
      expect do
        described_class.new.call(html: broken_html)
      end.to raise_error(described_class::Error, /unable to parse price/)
    end
  end
end
