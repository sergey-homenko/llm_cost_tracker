# frozen_string_literal: true

require "spec_helper"
require "price_scrape/providers/anthropic"

RSpec.describe LlmCostTracker::Pricing::Scrape::Providers::Anthropic do
  let(:fixture_path) { File.expand_path("../../../fixtures/scrape/anthropic_pricing.html", __dir__) }
  let(:html) { File.read(fixture_path, encoding: "utf-8") }
  let(:vertex_html) { File.read(fixture_path.sub("anthropic_pricing", "vertex_pricing"), encoding: "utf-8") }
  let(:vertex_url) { LlmCostTracker::Pricing::Scrape::Providers::Gemini::VERTEX_URL }

  def scrape(page = html, vertex: vertex_html, **)
    described_class.new.call(html: { described_class.source_url => page, vertex_url => vertex }, **)
  end

  describe "#call" do
    it "extracts current model pricing from the official page" do
      result = scrape(scraped_at: "2026-04-26T00:00:00Z")

      expect(result.source_url).to eq(described_class.source_url)
      expect(result.scraped_at).to eq("2026-04-26T00:00:00Z")
      expect(result.service_charges).to eq(
        "web_search_request" => 10.0,
        "web_fetch_request" => 0.0,
        "code_execution_hour" => 0.05
      )
      expect(result.models.fetch("claude-opus-4-7")).to include(
        "input" => 5.0,
        "cache_write_input" => 6.25,
        "cache_write_extended_input" => 10.0,
        "cache_read_input" => 0.5,
        "output" => 25.0,
        "batch_input" => 2.5,
        "batch_output" => 12.5,
        "data_residency_input" => 5.5,
        "data_residency_cache_write_input" => 6.875,
        "data_residency_cache_write_extended_input" => 11.0,
        "data_residency_cache_read_input" => 0.55,
        "data_residency_output" => 27.5,
        "data_residency_batch_input" => 2.75,
        "data_residency_batch_output" => 13.75
      )
      expect(result.models.fetch("claude-sonnet-4-6")).to eq(
        "input" => 3.0,
        "cache_write_input" => 3.75,
        "cache_write_extended_input" => 6.0,
        "cache_read_input" => 0.30,
        "output" => 15.0,
        "batch_input" => 1.5,
        "batch_output" => 7.5,
        "data_residency_input" => 3.3,
        "data_residency_cache_write_input" => 4.125,
        "data_residency_cache_write_extended_input" => 6.6,
        "data_residency_cache_read_input" => 0.33,
        "data_residency_output" => 16.5,
        "data_residency_batch_input" => 1.65,
        "data_residency_batch_output" => 8.25
      )
      expect(result.models.fetch("claude-haiku-4-5")).to include(
        "input" => 1.0,
        "output" => 5.0,
        "batch_input" => 0.5,
        "batch_output" => 2.5
      )
      expect(result.models.fetch("claude-haiku-4-5")).to include(
        "data_residency_input" => 1.1, "data_residency_output" => 5.5, "data_residency_cache_read_input" => 0.11,
        "data_residency_cache_write_input" => 1.375, "data_residency_cache_write_extended_input" => 2.2,
        "data_residency_batch_input" => 0.55, "data_residency_batch_output" => 2.75
      )
      expect(result.models.fetch("claude-fable-5")).to include(
        "input" => 10.0,
        "cache_write_input" => 12.5,
        "cache_write_extended_input" => 20.0,
        "cache_read_input" => 1.0,
        "output" => 50.0,
        "batch_input" => 5.0,
        "batch_output" => 25.0,
        "data_residency_input" => 11.0,
        "data_residency_output" => 55.0
      )
      expect(result.models.fetch("claude-mythos-5")).to include("input" => 10.0, "output" => 50.0)
    end

    it "selects the date-scoped pricing row effective at scrape time" do
      through = html.gsub(">Claude Sonnet 5</a>", ">Claude Sonnet 5 through September 30, 2026</a>")
      expect(scrape(through, scraped_at: "2026-09-03T00:00:00Z").models)
        .to include("claude-sonnet-5" => hash_including("input" => 2.0, "output" => 10.0, "batch_input" => 1.0))
      expect(scrape(through, scraped_at: "2026-10-01T00:00:00Z").models)
        .not_to include("claude-sonnet-5")

      starting = html.gsub(">Claude Sonnet 5</a>", ">Claude Sonnet 5 starting October 1, 2026</a>")
      expect(scrape(starting, scraped_at: "2026-09-03T00:00:00Z").models)
        .not_to include("claude-sonnet-5")
      expect(scrape(starting, scraped_at: "2026-10-01T00:00:00Z").models)
        .to include("claude-sonnet-5" => hash_including("input" => 2.0, "output" => 10.0))
    end

    it "names a Claude model of any family from its display name" do
      renamed = html.gsub(">Claude Mythos 5.1</a>", ">Claude Lyra 6</a>")
      models = scrape(renamed, scraped_at: "2026-10-05T00:00:00Z").models

      expect(models.fetch("claude-lyra-6")).to include(
        "input" => 10.0, "cache_read_input" => 0.25, "output" => 50.0, "batch_input" => 5.0, "data_residency_input" => 11.0
      )
      expect(models).not_to include("claude-mythos-5-1")
    end

    it "raises on a priced row whose name is not a Claude model name" do
      renamed = html.sub(">Claude Sonnet 5</a>", ">Claude 5 Sonnet</a>")

      expect { scrape(renamed, scraped_at: "2026-10-05T00:00:00Z") }
        .to raise_error(described_class::Error, /no model ID for Anthropic price row "Claude 5 Sonnet"/)
    end

    it "scrapes fast mode pricing per model and stacks the data residency multiplier" do
      six_x_row = "<tr><td>Claude Opus 4.7</td><td>$30 / MTok</td><td>$150 / MTok</td></tr>"
      with_six_x = html.sub(%r{<tr>\s*<td[^>]*>Claude Opus 5 / Claude Opus 4\.8<}, "#{six_x_row}\\0")
      result = scrape(with_six_x)

      expect(result.models.fetch("claude-opus-4-7")).to include(
        "fast_input" => 30.0, "fast_output" => 150.0,
        "fast_cache_read_input" => 3.0, "fast_cache_write_input" => 37.5,
        "fast_data_residency_input" => 33.0, "fast_data_residency_output" => 165.0
      )

      %w[claude-opus-5 claude-opus-4-8].each do |model_id|
        expect(result.models.fetch(model_id)).to include(
          "fast_input" => 10.0, "fast_output" => 50.0,
          "fast_cache_read_input" => 1.0, "fast_cache_write_input" => 12.5,
          "fast_data_residency_input" => 11.0, "fast_data_residency_output" => 55.0
        )
      end

      expect(result.models.fetch("claude-opus-4-6")).not_to include("fast_input")
      expect(result.models.fetch("claude-sonnet-4-6")).not_to include("fast_input")
    end

    it "prices Claude Haiku 5.5 prompts over 100,000 tokens at its long-context rows, batch and data residency too" do
      expect(scrape.models.fetch("claude-haiku-5-5")).to include(
        "_context_price_threshold_tokens" => 100_000, "input" => 0.1, "output" => 0.5, "cache_read_input" => 0.01,
        "above_context_input" => 0.5, "above_context_output" => 2.5, "above_context_cache_read_input" => 0.05,
        "above_context_cache_write_input" => 0.625, "above_context_cache_write_extended_input" => 1.0,
        "above_context_batch_input" => 0.25, "above_context_batch_output" => 1.25,
        "above_context_data_residency_input" => 0.55, "above_context_data_residency_batch_output" => 1.375
      )
      expect { scrape(html.sub("for prompts over 100,000 tokens", "")) }
        .to raise_error(described_class::Error, /claude-haiku-5-5 are not one row or an up-to and over/)
    end

    it "prices Claude models above 200K input tokens at Vertex AI's long-context rates where they differ" do
      expect(scrape.models.fetch("claude-sonnet-4-5")).to include(
        "_context_price_threshold_tokens" => 200_000, "above_context_input" => 6.0, "above_context_output" => 22.5,
        "above_context_cache_read_input" => 0.6, "above_context_cache_write_input" => 7.5,
        "above_context_cache_write_extended_input" => 12.0, "above_context_batch_input" => 3.0,
        "above_context_data_residency_input" => 6.6, "above_context_data_residency_batch_output" => 12.375
      )
      expect(scrape.models.fetch("claude-sonnet-4-6")).not_to include("_context_price_threshold_tokens")
      expect { scrape(vertex: "<html></html>") }.to raise_error(described_class::Error, /Claude Global pricing table/)
      typo = vertex_html.sub(%r{1h (Cache Write</p></td><td><p>\$6\.00</p></td><td><p>\$12)}, '1hr \1')
      expect { scrape(vertex: typo) }
        .to raise_error(described_class::Error, /long-context prices for Claude Sonnet 4.5 do not extend/)
    end

    it "keeps retired models Anthropic still serves on Bedrock or Google Cloud, Claude 3 ones under their API id" do
      result = scrape

      expect(result.deprecated_models).to eq([])
      expect(result.models).to include(
        "claude-opus-4-1" => { "input" => 15.0, "cache_write_input" => 18.75, "cache_write_extended_input" => 30.0,
                               "cache_read_input" => 1.5, "output" => 75.0, "batch_input" => 7.5, "batch_output" => 37.5 },
        "claude-opus-4" => hash_including("input" => 15.0, "output" => 75.0),
        "claude-sonnet-4" => hash_including("input" => 3.0, "output" => 15.0, "batch_input" => 1.5),
        "claude-3-5-haiku" => { "input" => 0.8, "cache_write_input" => 1.0, "cache_write_extended_input" => 1.6,
                                "cache_read_input" => 0.08, "output" => 4.0, "batch_input" => 0.4, "batch_output" => 2.0 }
      )
    end

    it "flags a model retired everywhere as deprecated" do
      result = scrape(html.gsub("retired, except on Google Cloud.", "retired."))

      expect(result.deprecated_models).to eq(["claude-opus-4"])
    end

    it "raises when a retired row loses its lifecycle note or the note's wording changes" do
      expect { scrape(html.gsub("lifecycle", "status")) }
        .to raise_error(described_class::Error, /retired row "Claude Opus 4.1" has no lifecycle note/)
      expect { scrape(html.gsub("retired, except on Google Cloud.", "still on Google Cloud.")) }
        .to raise_error(described_class::Error, /lifecycle note for Claude Opus 4 not understood/)
    end

    it "leaves deprecated_models empty when the page marks no model as retired" do
      stripped = html.gsub(" (Retired)", "")
      result = scrape(stripped)

      expect(result.deprecated_models).to eq([])
    end

    it "returns at least the minimum expected number of models" do
      result = scrape
      expect(result.models.size).to be >= described_class.min_models
    end

    it "raises when the base pricing table is missing" do
      expect do
        scrape("<html><body></body></html>")
      end.to raise_error(described_class::Error, /base pricing table not found/)
    end

    it "raises when the parsed model count is below the minimum" do
      sparse_html = <<~HTML
        <html><body>
          <table>
            <thead>
              <tr><th>Model</th><th colspan="2">Base Tokens</th><th colspan="3">Prompt caching</th></tr>
              <tr>
                <th>Name</th><th>Input</th><th>Output</th>
                <th>5m writes</th><th>1h writes</th><th>Hits and refreshes</th>
              </tr>
            </thead>
            <tbody>
              <tr><td>Claude Opus 4.7</td><td>$5 / MTok</td><td>$25 / MTok</td>
                <td>$6.25 / MTok</td><td>$10 / MTok</td><td>$0.50 / MTok</td></tr>
            </tbody>
          </table>
          <table>
            <thead><tr><th>Model</th><th>Input</th><th>Output</th></tr></thead>
            <tbody><tr><td>Claude Opus 4.7</td><td>$30 / MTok</td><td>$150 / MTok</td></tr></tbody>
          </table>
        </body></html>
      HTML

      expect do
        scrape(sparse_html)
      end.to raise_error(described_class::Error, /at least \d+ models/)
    end

    it "raises when the regional endpoint premium note stops matching" do
      expect do
        scrape(html.gsub("include a 10% premium", "include a 15% premium"))
      end.to raise_error(described_class::Error, /regional endpoint premium note/)
    end

    it "raises when a service charge sentence stops matching" do
      broken_html = html.gsub("per 1,000 searches", "per 1,000 lookups")
      expect do
        scrape(broken_html)
      end.to raise_error(described_class::Error, /service charge price not found/)
    end

    it "raises when a price cell does not match the expected format" do
      broken_html = html.sub(">$4<!-- -->", ">TBD<!-- -->")
      expect do
        scrape(broken_html)
      end.to raise_error(described_class::Error, /unable to parse price/)
    end

    it "derives batch pricing as half of base even when the upstream batch table is absent" do
      without_batch_table = html.gsub("Batch tokens", "Bulk tokens")

      result = scrape(without_batch_table)

      expect(result.models.fetch("claude-sonnet-4-6")).to include(
        "batch_input" => 1.5,
        "batch_output" => 7.5,
        "data_residency_batch_input" => 1.65,
        "data_residency_batch_output" => 8.25
      )
      expect(result.models.count { |_, fields| fields.key?("batch_input") }).to eq(result.models.size)
    end

    it "raises when the fast mode pricing table is missing rather than silently dropping fast prices" do
      without_fast_table = html.sub(%r{(<th[^>]*>Model</th><th[^>]*>)Input(</th>)}, "\\1Speed\\2")

      expect do
        scrape(without_fast_table)
      end.to raise_error(described_class::Error, /fast mode pricing table not found/)
    end
  end

  describe "#verify_batch_discount!" do
    def batch_table(input:, output:)
      Nokogiri::HTML(
        "<table><thead><tr><th>Model</th><th colspan=\"2\">Batch tokens</th></tr>" \
        "<tr><th>Name</th><th>Input</th><th>Output</th></tr></thead>" \
        "<tbody><tr><td>Claude Opus 4.7</td><td>#{input} / MTok</td><td>#{output} / MTok</td></tr></tbody></table>"
      )
    end

    let(:base) { { "claude-opus-4-7" => { "input" => 5.0, "output" => 25.0 } } }

    it "passes when the upstream batch table still matches the flat discount" do
      doc = batch_table(input: "$2.50", output: "$12.50")

      expect { described_class.new.send(:verify_batch_discount!, doc, base) }.not_to raise_error
    end

    it "raises when the upstream batch table diverges from the flat discount" do
      doc = batch_table(input: "$4.00", output: "$12.50")

      expect do
        described_class.new.send(:verify_batch_discount!, doc, base)
      end.to raise_error(described_class::Error, /no longer 0.5 of base/)
    end
  end
end
