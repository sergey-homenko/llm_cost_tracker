# frozen_string_literal: true

require "cgi"
require "json"
require "spec_helper"
require "price_scrape/providers/openai"

RSpec.describe LlmCostTracker::Pricing::Scrape::Providers::Openai do
  let(:fixture_path) { File.expand_path("../../../fixtures/scrape/openai_pricing.html", __dir__) }
  let(:html) { File.read(fixture_path, encoding: "utf-8") }
  let(:deprecations_html) do
    File.read(File.expand_path("../../../fixtures/scrape/openai_deprecations.html", __dir__), encoding: "utf-8")
  end
  let(:long_context_sentence) do
    "Prompts with >272K input tokens are priced at 2x input and 1.5x output " \
      "for the full session for standard, batch, and flex."
  end
  let(:sparse_html) do
    pricing_html(
      {
        "tier" => [0, "standard"],
        "rows" => [1, [[1, [[0, "gpt-5"], [0, 1.25], [0, 0.125], [0, 10]]]]]
      },
      {
        "tier" => [0, "batch"],
        "rows" => [1, [[1, [[0, "gpt-5"], [0, 0.625], [0, 0.0625], [0, 5]]]]]
      },
      {
        "tier" => [0, "flex"],
        "rows" => [1, [[1, [[0, "gpt-5"], [0, 0.625], [0, 0.0625], [0, 5]]]]]
      },
      {
        "tier" => [0, "fast"],
        "rows" => [1, [[1, [[0, "gpt-5"], [0, 2.5], [0, 0.25], [0, 20]]]]]
      }
    )
  end

  let(:standard_only_html) do
    props = {
      "tier" => [0, "standard"],
      "rows" => [1, [[1, [[0, "gpt-5"], [0, 1.25], [0, 0.125], [0, 10]]]]]
    }
    pricing_html(props)
  end

  def pricing_html(*props)
    islands = props.map do |payload|
      escaped_props = CGI.escapeHTML(JSON.generate(payload))
      "<astro-island component-url=\"/_astro/pricing.test.js\" props=\"#{escaped_props}\"></astro-island>"
    end
    "<html><body>#{islands.join}</body></html>"
  end

  def model_doc_html(body)
    "<html><body><p>#{body}</p></body></html>"
  end

  def html_pages(overrides = {})
    documented = described_class::DocumentedLongContextPrices
    pages = {
      described_class.source_url => html,
      described_class::DeprecatedModels::SOURCE_URL => deprecations_html
    }
    documented.source_urls.each do |url|
      pages[url] = model_doc_html(url.end_with?("gpt-5.5-pro") ? "1,050,000 context window" : long_context_sentence)
    end
    pages.merge(overrides)
  end

  describe "#call" do
    it "extracts standard and batch text input/output rates for current models" do
      result = described_class.new.call(html: html_pages, scraped_at: "2026-08-23T00:00:00Z")

      expect(result.source_url).to eq(described_class.source_url)
      expect(result.scraped_at).to eq("2026-08-23T00:00:00Z")
      expect(result.service_charges).to eq(
        "web_search_request" => 10.0,
        "web_search_preview_request_reasoning" => 10.0,
        "web_search_preview_request_non_reasoning" => 25.0,
        "file_search_call" => 2.5
      )
      expect(result.models.fetch("gpt-5.5")).to include(
        "input" => 5.0,
        "cache_read_input" => 0.5,
        "output" => 30.0,
        "batch_input" => 2.5,
        "batch_cache_read_input" => 0.25,
        "batch_output" => 15.0,
        "_context_price_threshold_tokens" => 272_000,
        "above_context_input" => 10.0,
        "above_context_cache_read_input" => 1.0,
        "above_context_output" => 45.0,
        "above_context_batch_input" => 5.0,
        "above_context_batch_cache_read_input" => 0.5,
        "above_context_batch_output" => 22.5,
        "flex_input" => 2.5,
        "flex_cache_read_input" => 0.25,
        "flex_output" => 15.0,
        "above_context_flex_input" => 5.0,
        "above_context_flex_cache_read_input" => 0.5,
        "above_context_flex_output" => 22.5,
        "fast_input" => 12.5,
        "fast_cache_read_input" => 1.25,
        "fast_output" => 75.0,
        "priority_input" => 12.5,
        "priority_cache_read_input" => 1.25,
        "priority_output" => 75.0,
        "data_residency_input" => 5.5,
        "data_residency_cache_read_input" => 0.55,
        "data_residency_output" => 33.0,
        "fast_data_residency_input" => 13.75,
        "fast_data_residency_cache_read_input" => 1.375,
        "fast_data_residency_output" => 82.5,
        "priority_data_residency_input" => 13.75,
        "priority_data_residency_cache_read_input" => 1.375,
        "priority_data_residency_output" => 82.5
      )
      expect(result.models.fetch("gpt-5.4-mini")).to include(
        "input" => 0.75,
        "cache_read_input" => 0.075,
        "output" => 4.5,
        "batch_input" => 0.375,
        "batch_cache_read_input" => 0.0375,
        "batch_output" => 2.25,
        "flex_input" => 0.375,
        "flex_cache_read_input" => 0.0375,
        "flex_output" => 2.25,
        "fast_input" => 1.5,
        "fast_cache_read_input" => 0.15,
        "fast_output" => 9.0,
        "priority_input" => 1.5,
        "priority_cache_read_input" => 0.15,
        "priority_output" => 9.0,
        "data_residency_input" => 0.825,
        "data_residency_cache_read_input" => 0.0825,
        "data_residency_output" => 4.95,
        "fast_data_residency_input" => 1.65,
        "fast_data_residency_cache_read_input" => 0.165,
        "fast_data_residency_output" => 9.9,
        "priority_data_residency_input" => 1.65,
        "priority_data_residency_cache_read_input" => 0.165,
        "priority_data_residency_output" => 9.9
      )
      expect(result.models.fetch("gpt-5.6-sol")).to include(
        "input" => 5.0,
        "cache_read_input" => 0.5,
        "cache_write_input" => 6.25,
        "output" => 30.0,
        "batch_input" => 2.5,
        "batch_cache_read_input" => 0.25,
        "batch_cache_write_input" => 3.125,
        "batch_output" => 15.0,
        "fast_input" => 10.0,
        "fast_cache_write_input" => 12.5,
        "priority_input" => 10.0,
        "priority_cache_write_input" => 12.5,
        "_context_price_threshold_tokens" => 272_000,
        "above_context_input" => 10.0,
        "above_context_cache_read_input" => 1.0,
        "above_context_cache_write_input" => 12.5,
        "above_context_output" => 45.0,
        "data_residency_input" => 5.5,
        "data_residency_cache_write_input" => 6.875,
        "data_residency_output" => 33.0
      )
      expect(result.models.fetch("gpt-4-turbo")).to eq(
        "input" => 10.0,
        "output" => 30.0,
        "batch_input" => 5.0,
        "batch_output" => 15.0
      )
      expect(result.models.fetch("gpt-5.3-codex")).to eq(
        "input" => 1.75,
        "cache_read_input" => 0.175,
        "output" => 14.0,
        "fast_input" => 3.5,
        "fast_cache_read_input" => 0.35,
        "fast_output" => 28.0,
        "priority_input" => 3.5,
        "priority_cache_read_input" => 0.35,
        "priority_output" => 28.0
      )
      expect(result.models.fetch("o3-pro")).to eq(
        "input" => 20.0,
        "output" => 80.0,
        "batch_input" => 10.0,
        "batch_output" => 40.0
      )
      expect(result.models.fetch("gpt-5.5-pro")).to include(
        "data_residency_input" => 33.0,
        "data_residency_output" => 198.0,
        "flex_data_residency_input" => 16.5,
        "flex_data_residency_output" => 99.0
      )
      expect(result.models.fetch("gpt-realtime-1.5")).to eq(
        "input" => 4.0,
        "cache_read_input" => 0.4,
        "output" => 16.0,
        "audio_input" => 32.0,
        "audio_output" => 64.0,
        "image_input" => 5.0
      )
      expect(result.models.fetch("gpt-realtime-mini")).to eq(
        "input" => 0.6,
        "cache_read_input" => 0.06,
        "output" => 2.4,
        "audio_input" => 10.0,
        "audio_output" => 20.0,
        "image_input" => 0.8
      )
      expect(result.models.fetch("gpt-audio-1.5")).to eq(
        "input" => 2.5,
        "output" => 10.0,
        "audio_input" => 32.0,
        "audio_output" => 64.0
      )
      expect(result.models.fetch("gpt-image-1")).to eq(
        "input" => 5.0, "cache_read_input" => 1.25,
        "image_input" => 10.0, "image_output" => 40.0,
        "batch_input" => 2.5, "batch_cache_read_input" => 0.63,
        "batch_image_input" => 5.0, "batch_image_output" => 20.0
      )
      expect(result.models.fetch("gpt-image-1-mini")).to eq(
        "input" => 2.0, "cache_read_input" => 0.2,
        "image_input" => 2.5, "image_output" => 8.0,
        "batch_input" => 1.0, "batch_cache_read_input" => 0.1,
        "batch_image_input" => 1.25, "batch_image_output" => 4.0
      )
      expect(result.models.fetch("gpt-image-1.5")).to eq(
        "input" => 5.0, "cache_read_input" => 1.25, "output" => 10.0,
        "image_input" => 8.0, "image_output" => 32.0,
        "batch_input" => 2.5, "batch_cache_read_input" => 0.63, "batch_output" => 5.0,
        "batch_image_input" => 4.0, "batch_image_output" => 16.0
      )
      expect(result.models.fetch("gpt-image-2")).to eq(
        "input" => 5.0, "cache_read_input" => 1.25,
        "image_input" => 8.0, "image_output" => 30.0,
        "batch_input" => 2.5, "batch_cache_read_input" => 0.625,
        "batch_image_input" => 4.0, "batch_image_output" => 15.0
      )
    end

    it "returns at least the minimum expected number of models" do
      result = described_class.new.call(html: html_pages, scraped_at: "2026-08-23T00:00:00Z")
      expect(result.models.size).to be >= described_class.min_models
    end

    it "reports models whose published shutdown date has passed" do
      result = described_class.new.call(html: html_pages, scraped_at: "2026-08-23T00:00:00Z")

      expect(result.deprecated_models).to contain_exactly(
        "gpt-5.1-codex", "gpt-4o-realtime-preview", "chatgpt-4o-latest",
        "codex-mini-latest", "codex-mini", "codex-mini-completions", "ft-gpt-4o-mini"
      )
    end

    it "keeps models whose shutdown date is still ahead" do
      result = described_class.new.call(html: html_pages, scraped_at: "2026-08-23T00:00:00Z")

      expect(result.deprecated_models).not_to include("o4-mini", "Assistants API")
    end

    it "raises when the deprecations tables are missing" do
      expect do
        described_class.new.call(
          html: html_pages(described_class::DeprecatedModels::SOURCE_URL => "<html><body></body></html>")
        )
      end.to raise_error(described_class::Error, /deprecations tables not found/)
    end

    it "prices documented long context on the tiers the model page names" do
      result = described_class.new.call(html: html_pages, scraped_at: "2026-08-23T00:00:00Z")
      fields = result.models.fetch("gpt-5.5")

      expect(fields).to include(
        "_context_price_threshold_tokens" => 272_000,
        "above_context_input" => fields.fetch("input") * 2,
        "above_context_output" => fields.fetch("output") * 1.5,
        "above_context_cache_read_input" => fields.fetch("cache_read_input") * 2,
        "above_context_batch_input" => fields.fetch("batch_input") * 2,
        "above_context_flex_output" => fields.fetch("flex_output") * 1.5
      )
      expect(fields.keys).not_to include("above_context_fast_input", "above_context_priority_input")
    end

    it "warns instead of guessing when a model page documents no long-context premium" do
      expect do
        described_class.new.call(html: html_pages, scraped_at: "2026-08-23T00:00:00Z")
      end.to output(/no documented long-context premium for gpt-5.5-pro/).to_stderr

      result = described_class.new.call(html: html_pages, scraped_at: "2026-08-23T00:00:00Z")
      expect(result.models.fetch("gpt-5.5-pro")).not_to include("_context_price_threshold_tokens")
    end

    it "prices duration-billed audio models from the per-minute column" do
      result = described_class.new.call(html: html_pages, scraped_at: "2026-08-23T00:00:00Z")

      expect(result.models.fetch("gpt-transcribe")).to eq("transcription_minute" => 0.0045)
      expect(result.models.fetch("gpt-live-transcribe")).to eq("transcription_minute" => 0.017)
    end

    it "leaves token-billed transcription models off the per-minute rate" do
      result = described_class.new.call(html: html_pages, scraped_at: "2026-08-23T00:00:00Z")

      per_minute = result.models.select { |_, prices| prices.key?("transcription_minute") }
      expect(per_minute.keys).to contain_exactly("gpt-transcribe", "gpt-live-transcribe")
    end

    it "skips unmapped model rows instead of guessing canonical IDs" do
      result = described_class.new.call(html: html_pages, scraped_at: "2026-08-23T00:00:00Z")

      expect(result.models).not_to include("gpt-4-32k", "davinci-002", "babbage-002")
    end

    it "raises when the standard pricing table is missing" do
      expect do
        described_class.new.call(html: html_pages(described_class.source_url => "<html><body></body></html>"))
      end.to raise_error(described_class::Error, /standard pricing table not found/)
    end

    it "raises when the batch pricing table is missing" do
      expect do
        described_class.new.call(html: html_pages(described_class.source_url => standard_only_html))
      end.to raise_error(described_class::Error, /batch pricing table not found/)
    end

    it "raises when the parsed model count is below the minimum" do
      expect do
        described_class.new.call(html: html_pages(described_class.source_url => sparse_html))
      end.to raise_error(described_class::Error, /at least \d+ models/)
    end

    it "raises when a price cell does not match the expected format" do
      broken_html = html.sub(
        "[0,5],[0,0.5],[0,&quot;-&quot;],[0,30]", "[0,&quot;TBD&quot;],[0,0.5],[0,&quot;-&quot;],[0,30]"
      )

      expect do
        described_class.new.call(html: html_pages(described_class.source_url => broken_html))
      end.to raise_error(described_class::Error, /unable to parse price/)
    end

    it "raises when a batch price cell does not match the expected format" do
      broken_html = html.sub(
        "[0,2.5],[0,0.25],[0,3.125],[0,15]", "[0,&quot;TBD&quot;],[0,0.25],[0,3.125],[0,15]"
      )

      expect do
        described_class.new.call(html: html_pages(described_class.source_url => broken_html))
      end.to raise_error(described_class::Error, /unable to parse price/)
    end
  end
end
