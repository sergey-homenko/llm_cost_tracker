# frozen_string_literal: true

require "spec_helper"
require "price_scrape/providers/groq"

RSpec.describe LlmCostTracker::Pricing::Scrape::Providers::Groq do
  let(:models_html) { File.read("spec/fixtures/scrape/groq_models.html", encoding: "utf-8") }
  let(:prompt_caching_html) { File.read("spec/fixtures/scrape/groq_prompt_caching.html", encoding: "utf-8") }
  let(:flex_processing_html) { File.read("spec/fixtures/scrape/groq_flex_processing.html", encoding: "utf-8") }
  let(:combined_html) do
    <<~HTML
      <html>
        <body>
          <h2>Production Models</h2>
          #{minimal_models_table(span_ids: false)}
          <h2>Supported Models</h2>
          <p><code>openai/gpt-oss-20b</code></p>
          <p><code>openai/gpt-oss-120b</code></p>
          <h2>Pricing</h2>
          <p>Prompt caching has a 50% discount for cached input tokens.</p>
          <p>Flex has the same pricing as on-demand processing. Pricing matches the on-demand tier.</p>
        </body>
      </html>
    HTML
  end

  def html_pages(overrides = {})
    {
      described_class::SOURCE_URL => models_html,
      described_class::PROMPT_CACHING_SOURCE_URL => prompt_caching_html,
      described_class::FLEX_PROCESSING_SOURCE_URL => flex_processing_html
    }.merge(overrides)
  end

  def minimal_models_table(span_ids: true)
    model_cell = lambda do |label, id|
      span_ids ? "#{label}<span class=\"font-mono\">#{id}</span>" : "#{label} #{id}"
    end

    <<~HTML
      <table>
        <thead>
          <tr>
            <th>MODEL ID</th>
            <th>PRICE PER 1M TOKENS</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>#{model_cell.call('Llama 3.1 8B', 'llama-3.1-8b-instant')}</td>
            <td>$0.05 input $0.08 output</td>
          </tr>
          <tr>
            <td>#{model_cell.call('Llama 3.3 70B', 'llama-3.3-70b-versatile')}</td>
            <td>$0.59 input $0.79 output</td>
          </tr>
          <tr>
            <td>#{model_cell.call('GPT OSS 120B', 'openai/gpt-oss-120b')}</td>
            <td>$0.15 input $0.60 output</td>
          </tr>
          <tr>
            <td>#{model_cell.call('GPT OSS 20B', 'openai/gpt-oss-20b')}</td>
            <td>$0.075 input $0.30 output</td>
          </tr>
        </tbody>
      </table>
    HTML
  end

  describe "#call" do
    it "extracts production text model prices and derived Groq mode rates" do
      result = described_class.new.call(html: html_pages, scraped_at: "2026-05-01T00:00:00Z")

      expect(result.source_url).to eq(described_class::SOURCE_URL)
      expect(result.scraped_at).to eq("2026-05-01T00:00:00Z")
      expect(result.models.fetch("llama-3.1-8b-instant")).to eq(
        "input" => 0.05,
        "output" => 0.08,
        "on_demand_input" => 0.05,
        "on_demand_output" => 0.08,
        "flex_input" => 0.05,
        "flex_output" => 0.08
      )
      expect(result.models.fetch("openai/gpt-oss-20b")).to eq(
        "input" => 0.075,
        "output" => 0.3,
        "on_demand_input" => 0.075,
        "on_demand_output" => 0.3,
        "flex_input" => 0.075,
        "flex_output" => 0.3,
        "cache_read_input" => 0.0375,
        "on_demand_cache_read_input" => 0.0375,
        "flex_cache_read_input" => 0.0375
      )
      expect(result.models).not_to include("whisper-large-v3", "groq/compound", "openai/gpt-oss-safeguard-20b")
    end

    it "extracts prices from a single HTML document with text model identifiers" do
      result = described_class.new.call(html: combined_html)

      expect(result.models.fetch("openai/gpt-oss-20b")).to include(
        "input" => 0.075,
        "cache_read_input" => 0.0375,
        "output" => 0.3
      )
    end

    it "finds the production table by headers when the heading is absent" do
      result = described_class.new.call(
        html: html_pages(described_class::SOURCE_URL => "<html><body>#{minimal_models_table}</body></html>")
      )

      expect(result.models.fetch("llama-3.1-8b-instant")).to include(
        "input" => 0.05,
        "output" => 0.08
      )
    end

    it "returns at least the minimum expected number of models" do
      result = described_class.new.call(html: html_pages)
      expect(result.models.size).to be >= described_class::MIN_MODELS_EXPECTED
    end

    it "sets deprecated_models to empty" do
      result = described_class.new.call(html: html_pages)
      expect(result.deprecated_models).to eq([])
    end

    it "raises when the production models table is missing" do
      expect do
        described_class.new.call(html: html_pages(described_class::SOURCE_URL => "<html><body></body></html>"))
      end.to raise_error(described_class::Error, /production models pricing table not found/)
    end

    it "raises when another section starts before the production table" do
      models_html = <<~HTML
        <html>
          <body>
            <h2 id="production-models">Production Models</h2>
            <h2>Preview Models</h2>
            #{minimal_models_table}
          </body>
        </html>
      HTML

      expect do
        described_class.new.call(html: html_pages(described_class::SOURCE_URL => models_html))
      end.to raise_error(described_class::Error, /production models pricing table not found/)
    end

    it "raises when prompt caching supported models are missing" do
      prompt_html = prompt_caching_html.sub("<h2>Supported Models</h2>", "<h2>Supported Models</h2><h2>Pricing</h2>")

      expect do
        described_class.new.call(html: html_pages(described_class::PROMPT_CACHING_SOURCE_URL => prompt_html))
      end.to raise_error(described_class::Error, /prompt caching models/)
    end

    it "raises when prompt caching discount text is missing" do
      prompt_html = prompt_caching_html.sub("50% discount", "discount")

      expect do
        described_class.new.call(html: html_pages(described_class::PROMPT_CACHING_SOURCE_URL => prompt_html))
      end.to raise_error(described_class::Error, /prompt caching discount/)
    end

    it "raises when flex pricing is no longer documented as on-demand pricing" do
      flex_html = flex_processing_html.sub("same pricing as on-demand", "different pricing")
                                      .sub("Pricing matches the on-demand tier.", "Pricing differs.")

      expect do
        described_class.new.call(html: html_pages(described_class::FLEX_PROCESSING_SOURCE_URL => flex_html))
      end.to raise_error(described_class::Error, /flex on-demand pricing/)
    end

    it "raises when a production text price cannot be parsed" do
      broken_html = models_html.sub("$0.075", "TBD")

      expect do
        described_class.new.call(html: html_pages(described_class::SOURCE_URL => broken_html))
      end.to raise_error(described_class::Error, /unable to parse input price/)
    end
  end
end
