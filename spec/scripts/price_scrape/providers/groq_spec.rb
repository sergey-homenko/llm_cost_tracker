# frozen_string_literal: true

require "spec_helper"
require "price_scrape/providers/groq"

RSpec.describe LlmCostTracker::Pricing::Scrape::Providers::Groq do
  let(:models_html) { File.read("spec/fixtures/scrape/groq_models.html", encoding: "utf-8") }
  let(:prompt_caching_html) { File.read("spec/fixtures/scrape/groq_prompt_caching.html", encoding: "utf-8") }
  let(:flex_processing_html) { File.read("spec/fixtures/scrape/groq_flex_processing.html", encoding: "utf-8") }

  def html_pages(overrides = {})
    {
      described_class.source_url => models_html,
      described_class::PROMPT_CACHING_SOURCE_URL => prompt_caching_html,
      described_class::FLEX_PROCESSING_SOURCE_URL => flex_processing_html
    }.merge(overrides)
  end

  def text_models_table(rows)
    body = rows.map do |row|
      card = row[:card] || row[:id]
      price = row.fetch(:price) do
        "<span>$#{row[:input]}<!-- --> <span>input</span></span>" \
          "<span>$#{row[:output]}<!-- --> <span>output</span></span>"
      end
      <<~ROW
        <tr>
          <td><a href="/docs/model/#{card}">#{row[:name]}</a><span>#{row[:id]}</span></td>
          <td>500</td>
          <td>#{price}</td>
          <td>250K<!-- --> TPM</td>
        </tr>
      ROW
    end.join

    <<~HTML
      <table>
        <thead>
          <tr>
            <th>MODEL ID</th>
            <th>SPEED (T/SEC)</th>
            <th>PRICE PER 1M TOKENS</th>
            <th>RATE LIMITS (DEVELOPER PLAN)</th>
          </tr>
        </thead>
        <tbody>#{body}</tbody>
      </table>
    HTML
  end

  def models_page(table)
    "<html><body><h1>Supported Models</h1>#{table}</body></html>"
  end

  describe "#call" do
    it "extracts token model prices from the models page and derives Groq mode rates" do
      result = described_class.new.call(html: html_pages, scraped_at: "2026-05-01T00:00:00Z")

      expect(result.source_url).to eq(described_class.source_url)
      expect(result.scraped_at).to eq("2026-05-01T00:00:00Z")
      expect(result.models.fetch("qwen/qwen3.6-27b")).to eq(
        "input" => 0.6,
        "output" => 3.0,
        "on_demand_input" => 0.6,
        "on_demand_output" => 3.0,
        "flex_input" => 0.6,
        "flex_output" => 3.0
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
    end

    it "reads the model id from the model card link rather than the display name" do
      result = described_class.new.call(html: html_pages)

      expect(result.models.keys).to include("llama-3.3-70b-versatile", "openai/gpt-oss-120b")
    end

    it "merges token models from the production and preview tables" do
      result = described_class.new.call(html: html_pages)

      expect(result.models.keys).to include("llama-3.1-8b-instant", "qwen/qwen3.6-27b")
    end

    it "skips rows priced per hour, per character, or on request" do
      result = described_class.new.call(html: html_pages)

      expect(result.models.keys).not_to include(
        "whisper-large-v3",
        "canopylabs/orpheus-v1-english",
        "minimaxai/minimax-m2.7"
      )
    end

    it "skips rows that link to a system rather than a model card" do
      result = described_class.new.call(html: html_pages)

      expect(result.models.keys).not_to include("groq/compound", "groq/compound-mini")
    end

    it "drops a row whose model card link collides with another model and keeps the consistent one" do
      page = models_page(
        text_models_table(
          [
            { name: "GPT OSS 120B", id: "openai/gpt-oss-120b", input: "0.15", output: "0.60" },
            {
              name: "Safety GPT OSS 20B",
              id: "openai/gpt-oss-safeguard-20b",
              card: "openai/gpt-oss-120b",
              input: "0.075",
              output: "0.30"
            },
            { name: "Llama 3.1 8B", id: "llama-3.1-8b-instant", input: "0.05", output: "0.08" },
            { name: "Llama 3.3 70B", id: "llama-3.3-70b-versatile", input: "0.59", output: "0.79" },
            { name: "GPT OSS 20B", id: "openai/gpt-oss-20b", input: "0.075", output: "0.30" }
          ]
        )
      )

      result = described_class.new.call(html: html_pages(described_class.source_url => page))

      expect(result.models.fetch("openai/gpt-oss-120b")).to include("input" => 0.15, "output" => 0.6)
      expect(result.models.size).to eq(4)
    end

    it "finds the token model table by headers when it is not the first table on the page" do
      decoy = "<table><thead><tr><th>Tool</th><th>Price</th></tr></thead>" \
              "<tbody><tr><td>Web Search</td><td>$5 / 1000 requests</td></tr></tbody></table>"
      text_table = text_models_table(
        [
          { name: "Llama 3.1 8B", id: "llama-3.1-8b-instant", input: "0.05", output: "0.08" },
          { name: "Llama 3.3 70B", id: "llama-3.3-70b-versatile", input: "0.59", output: "0.79" },
          { name: "GPT OSS 20B", id: "openai/gpt-oss-20b", input: "0.075", output: "0.30" },
          { name: "GPT OSS 120B", id: "openai/gpt-oss-120b", input: "0.15", output: "0.60" }
        ]
      )

      result = described_class.new.call(html: html_pages(described_class.source_url => models_page(decoy + text_table)))

      expect(result.models.fetch("llama-3.1-8b-instant")).to include("input" => 0.05, "output" => 0.08)
    end

    it "returns at least the minimum expected number of models" do
      result = described_class.new.call(html: html_pages)
      expect(result.models.size).to be >= described_class.min_models
    end

    it "sets deprecated_models to empty" do
      result = described_class.new.call(html: html_pages)
      expect(result.deprecated_models).to eq([])
    end

    it "raises when the token model table is missing" do
      expect do
        described_class.new.call(html: html_pages(described_class.source_url => "<html><body></body></html>"))
      end.to raise_error(described_class::Error, /token models pricing table not found/)
    end

    it "raises when two rows collide on a model id with no consistent display name" do
      page = models_page(
        text_models_table(
          [
            { name: "Alpha One", id: "alpha-one", card: "openai/gpt-oss-120b", input: "0.15", output: "0.60" },
            { name: "Beta Two", id: "beta-two", card: "openai/gpt-oss-120b", input: "0.30", output: "0.60" },
            { name: "Llama 3.1 8B", id: "llama-3.1-8b-instant", input: "0.05", output: "0.08" }
          ]
        )
      )

      expect do
        described_class.new.call(html: html_pages(described_class.source_url => page))
      end.to raise_error(described_class::Error, /ambiguous model id/)
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

    it "skips a row whose price cell labels only one side of the token price" do
      page = models_page(
        text_models_table(
          [
            { name: "Llama 3.1 8B", id: "llama-3.1-8b-instant", input: "0.05", output: "0.08" },
            { name: "Llama 3.3 70B", id: "llama-3.3-70b-versatile", price: "<span>$0.59<!-- --> <span>input</span>" },
            { name: "GPT OSS 20B", id: "openai/gpt-oss-20b", input: "0.075", output: "0.30" },
            { name: "GPT OSS 120B", id: "openai/gpt-oss-120b", input: "0.15", output: "0.60" },
            { name: "Qwen3.6 27B", id: "qwen/qwen3.6-27b", input: "0.60", output: "3.00" }
          ]
        )
      )

      result = described_class.new.call(html: html_pages(described_class.source_url => page))

      expect(result.models).not_to include("llama-3.3-70b-versatile")
      expect(result.models.keys).to include("qwen/qwen3.6-27b", "openai/gpt-oss-20b")
    end
  end
end
